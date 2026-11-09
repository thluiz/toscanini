#!/usr/bin/env python3
"""
Whisper GPU worker for HermesTools.
Usage: worker.py <mp3-path> <output-txt> <progress-file> [cores]

Device selection (select_model): GPU only inside a schedule window with gpu=true, with
no GPU cooldown open, holding the GPU lock and with at least MIN_FREE_VRAM_MB free
(large-v3 float16 uses ~5 GB of the 6 GB card) → large-v3 GPU float16. Otherwise it
takes one of the 2 CPU slots → large-v3 CPU int8. It never runs without a lock/slot.
"""
import sys
import os
import subprocess
import tempfile
import time
import json


def fmt_time(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def get_duration(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=30
        )
        return float(r.stdout.strip())
    except Exception:
        return None


def get_free_vram_mb():
    """Get free VRAM in MB via nvidia-smi."""
    try:
        r = subprocess.run(
            ["/usr/lib/wsl/lib/nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10
        )
        return int(r.stdout.strip())
    except Exception:
        return 0


GPU_LOCK = "/tmp/whisper-gpu.lock"
CPU_LOCK_PREFIX = "/tmp/whisper-cpu"
MAX_CPU_SLOTS = 2


def acquire_gpu_lock(quiet=False):
    """Try to acquire GPU lock. Returns True if acquired.
    Checks PID in existing lock — clears stale locks from dead processes.
    quiet: don't log "held by pid" (used while a job re-polls the lock)."""
    pid = str(os.getpid())
    try:
        fd = os.open(GPU_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, pid.encode())
        os.close(fd)
        print(f"GPU lock acquired (pid={pid})", file=sys.stderr)
        return True
    except FileExistsError:
        pass

    # Check if the PID in the lock is still alive
    try:
        held_pid = int(open(GPU_LOCK).read().strip())
        os.kill(held_pid, 0)  # signal 0: check existence only
        if not quiet:
            print(f"GPU lock held by pid={held_pid}, using CPU", file=sys.stderr)
        return False
    except (ValueError, FileNotFoundError):
        pass  # unreadable lock — treat as stale
    except ProcessLookupError:
        print(f"Stale GPU lock (pid dead), clearing", file=sys.stderr)

    # Stale lock — remove and re-acquire atomically via O_EXCL
    try:
        os.unlink(GPU_LOCK)
    except FileNotFoundError:
        pass
    try:
        fd = os.open(GPU_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, pid.encode())
        os.close(fd)
        print(f"GPU lock acquired after clearing stale (pid={pid})", file=sys.stderr)
        return True
    except FileExistsError:
        print(f"GPU lock lost race after clearing stale, using CPU", file=sys.stderr)
        return False


def release_gpu_lock():
    try:
        os.unlink(GPU_LOCK)
        print("GPU lock released", file=sys.stderr)
    except FileNotFoundError:
        pass


def try_acquire_cpu_slot(max_slots=MAX_CPU_SLOTS):
    """One pass over the CPU slots. Returns the slot number (0-based) or None if
    all are busy. Never runs without a slot: more than max_slots transcriptions
    on the CPU at once fight for the same cores and every one of them crawls."""
    pid = str(os.getpid())
    for i in range(max_slots):
        lock = f"{CPU_LOCK_PREFIX}-{i}.lock"
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, pid.encode())
            os.close(fd)
            print(f"CPU slot {i} acquired (pid={pid})", file=sys.stderr)
            return i
        except FileExistsError:
            # Check if stale
            try:
                held_pid = int(open(lock).read().strip())
                os.kill(held_pid, 0)
                continue  # alive, try next slot
            except (ProcessLookupError, ValueError, FileNotFoundError):
                # Stale — try to take over atomically
                try:
                    os.unlink(lock)
                except FileNotFoundError:
                    pass
                try:
                    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                    os.write(fd, pid.encode())
                    os.close(fd)
                    print(f"CPU slot {i} acquired after clearing stale (pid={pid})", file=sys.stderr)
                    return i
                except FileExistsError:
                    continue
    return None


def release_cpu_slot(slot):
    if slot < 0:
        return
    lock = f"{CPU_LOCK_PREFIX}-{slot}.lock"
    try:
        os.unlink(lock)
        print(f"CPU slot {slot} released", file=sys.stderr)
    except FileNotFoundError:
        pass


DATA_DIR = os.environ.get("TOSCANINI_DATA_DIR", "/home/hermes/services/toscanini/data")
WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def window_allows_gpu(schedules, now):
    """Mesma regra de Toscanini.Scheduler.window_for/2: a primeira janela que casa
    com a hora e o dia ('days' ausente = todos os dias) decide se a GPU vale."""
    day = WEEKDAYS[now.weekday()]
    for w in schedules.get("transcribe", []):
        days = w.get("days")
        if w["from"] <= now.hour < w["to"] and (days is None or day in days):
            return w.get("gpu", False)
    return False


def gpu_cooldown_active(now_ts=None):
    """Cooldown aberto pelo TranscribeWorker quando o whisper abortou na GPU (exit 134).
    Enquanto data/gpu_cooldown.json estiver no futuro, nada vai para a GPU."""
    try:
        until = json.load(open(os.path.join(DATA_DIR, "gpu_cooldown.json")))["until"]
        return (time.time() if now_ts is None else now_ts) < until
    except Exception:
        return False


SLOT_POLL_SECS = 5
# O large-v3 float16 ocupa ~5 GB dos 6 GB da RTX 3050: com menos que isto livre
# (algo mais usando a GPU), ele cai com CUDA out of memory. Em MiB, como o nvidia-smi.
MIN_FREE_VRAM_MB = int(os.environ.get("WHISPER_MIN_FREE_VRAM_MB", "5200"))
VRAM_WAIT_SECS = int(os.environ.get("WHISPER_VRAM_WAIT_SECS", "20"))


def select_model():
    """Blocks until it holds the GPU lock or a CPU slot — never runs without one.
    Each pass re-reads the window and the cooldown and retries the GPU lock, so a
    job that waited for a CPU slot moves to the GPU as soon as it opens up."""
    from datetime import datetime
    waited = False
    while True:
        gpu_allowed = False
        try:
            schedules = json.load(open(os.path.join(DATA_DIR, "queue_schedules.json")))
            gpu_allowed = window_allows_gpu(schedules, datetime.now())
        except Exception:
            # No config file — safe default: CPU only
            if not waited:
                print("No scheduler config found, defaulting to CPU", file=sys.stderr)
        if gpu_allowed and gpu_cooldown_active():
            if not waited:
                print("GPU in cooldown after a previous abort, using CPU", file=sys.stderr)
            gpu_allowed = False
        if gpu_allowed and acquire_gpu_lock(quiet=waited):
            # Com o lock em mãos, nenhum outro whisper pega a GPU: dá uma folga curta
            # para a VRAM do job anterior ser liberada. Se ainda assim não houver
            # VRAM para o large-v3, não vale começar na GPU só para cair.
            free = wait_for_vram(MIN_FREE_VRAM_MB, timeout=VRAM_WAIT_SECS)
            if free >= MIN_FREE_VRAM_MB:
                return "large-v3", "cuda", "float16", True, -1
            print(f"GPU skipped: only {free} MB VRAM free, need {MIN_FREE_VRAM_MB} MB",
                  file=sys.stderr)
            release_gpu_lock()
        cpu_slot = try_acquire_cpu_slot()
        if cpu_slot is not None:
            return "large-v3", "cpu", "int8", False, cpu_slot
        if not waited:
            print(f"GPU unavailable and all {MAX_CPU_SLOTS} CPU slots busy, waiting...",
                  file=sys.stderr)
            waited = True
        time.sleep(SLOT_POLL_SECS)


def wait_for_vram(target_mb=3500, timeout=45, interval=5):
    """Wait for VRAM to be freed (e.g. after previous job exited).
    Returns actual free VRAM after waiting."""
    free = get_free_vram_mb()
    if free >= target_mb:
        return free
    print(f"VRAM low ({free}MB free), waiting up to {timeout}s for release...",
          file=sys.stderr)
    elapsed = 0
    while elapsed < timeout:
        time.sleep(interval)
        elapsed += interval
        free = get_free_vram_mb()
        print(f"  VRAM check: {free}MB free (waited {elapsed}s)", file=sys.stderr)
        if free >= target_mb:
            print(f"VRAM freed: {free}MB available", file=sys.stderr)
            return free
    print(f"VRAM wait timeout: only {free}MB free after {timeout}s", file=sys.stderr)
    return free


def write_progress(progress_path, status, position="", duration_str="",
                   progress_pct=0.0, segments=0, elapsed_str="",
                   eta_str="", model_name="", error=""):
    with open(progress_path, "w") as pf:
        pf.write(f"status: {status}\n")
        pf.write(f"position: {position} / {duration_str}\n")
        pf.write(f"progress: {progress_pct:.1f}%\n")
        pf.write(f"segments: {segments}\n")
        pf.write(f"elapsed: {elapsed_str}\n")
        pf.write(f"eta: {eta_str}\n")
        pf.write(f"model: {model_name}\n")
        pf.write(f"updated: {time.strftime('%H:%M:%S')}\n")
        if error:
            pf.write(f"error: {error}\n")


LANG_MIN_PROB = 0.5


def sample_offsets(duration):
    """Offsets (s) to sample for language detection, best first.
    Skips the intro (300s or 10% on long audio) but never past 40% of the
    duration — on short videos a fixed 300s lands on the outro/end screen."""
    if not duration or duration <= 120:
        return [0]
    first = min(max(300, duration * 0.10), duration * 0.40)
    return [int(first), int(duration * 0.20), int(duration * 0.60)]


def detect_language_at(model, audio_path, offset):
    """Returns (lang, prob) for a 30s sample at offset, or None."""
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_path = tmp.name

        cmd = ["ffmpeg", "-nostdin", "-i", audio_path, "-ss", str(offset),
               "-t", "30", "-ar", "16000", "-ac", "1", tmp_path, "-y"]
        subprocess.run(cmd, capture_output=True, timeout=30)

        if not os.path.isfile(tmp_path) or os.path.getsize(tmp_path) == 0:
            print(f"Warning: could not extract sample at {offset}s", file=sys.stderr)
            return None

        _, lang_info = model.transcribe(tmp_path, beam_size=1)
        lang = lang_info.language
        prob = lang_info.language_probability
        print(f"Language detected: {lang} (prob={prob:.2f}, sampled at {offset}s)",
              file=sys.stderr)
        return lang, prob
    except Exception as e:
        print(f"Warning: language detection at {offset}s failed ({e})", file=sys.stderr)
        return None
    finally:
        if tmp_path and os.path.isfile(tmp_path):
            os.unlink(tmp_path)


def detect_language(model, audio_path, duration):
    """Sample audio away from the intro to detect language. Tries further
    samples while confidence is low; if none is confident, returns None so
    faster-whisper auto-detects instead of forcing a wrong language (a forced
    low-confidence guess on music/outro yields pure hallucination)."""
    best = None
    for offset in sample_offsets(duration):
        result = detect_language_at(model, audio_path, offset)
        if result is None:
            continue
        if best is None or result[1] > best[1]:
            best = result
        if best[1] >= LANG_MIN_PROB:
            return best[0]

    if best:
        print(f"Language confidence too low (best {best[0]} prob={best[1]:.2f}), using auto",
              file=sys.stderr)
    else:
        print("Warning: language detection failed, using auto", file=sys.stderr)
    return None


LOOP_MIN_LINES = 10
LOOP_MAX_TOP_SHARE = 0.5


def looping(lines):
    """Same criterion as Toscanini.TranscriptCheck: one line is >= 50% of all."""
    if len(lines) < LOOP_MIN_LINES:
        return False
    texts = [l.split("] ", 1)[-1] for l in lines]
    top = max(texts.count(t) for t in set(texts))
    return top / len(texts) >= LOOP_MAX_TOP_SHARE


def run_transcription(model, audio_path, lang, progress_path, model_name,
                      duration, duration_str, start_time, **opts):
    write_progress(progress_path, "transcribing", "00:00:00", duration_str,
                   0.0, 0, fmt_time(time.time() - start_time), "?", model_name)

    segments, _info = model.transcribe(audio_path, language=lang, **opts)

    last_progress_time = 0
    lines = []

    for s in segments:
        lines.append(f"[{fmt_time(s.start)}] {s.text.strip()}")

        now = time.time()
        if now - last_progress_time >= 30:
            elapsed = now - start_time
            pct = (s.end / duration * 100) if duration else 0
            eta_s = ((elapsed / s.end) * (duration - s.end)) if duration and s.end > 0 else 0
            write_progress(progress_path, "transcribing", fmt_time(s.end),
                           duration_str, pct, len(lines), fmt_time(elapsed),
                           fmt_time(eta_s), model_name)
            last_progress_time = now

    return lines


def transcribe(model, audio_path, output_path, progress_path, model_name, duration):
    """Run transcription and write output. Returns (success, seg_count, error_msg)."""
    detected_lang = detect_language(model, audio_path, duration)

    duration_str = fmt_time(duration) if duration else "?"
    start_time = time.time()

    lines = run_transcription(model, audio_path, detected_lang, progress_path,
                              model_name, duration, duration_str, start_time)

    if looping(lines):
        # The first window (show jingle, or a hallucination over intro music)
        # becomes the prompt for the next one and the model repeats it to the
        # end. Without conditioning on previous text the loop breaks at once.
        print(f"Loop detected ({len(lines)} segments), retrying with "
              f"condition_on_previous_text=False", file=sys.stderr)
        lines = run_transcription(model, audio_path, detected_lang, progress_path,
                                  model_name, duration, duration_str, start_time,
                                  condition_on_previous_text=False)

    seg_count = len(lines)

    # Write output atomically
    with open(output_path, "w") as f:
        f.write("\n".join(lines) + "\n" if lines else "")

    elapsed = time.time() - start_time
    write_progress(progress_path, "completed", duration_str, duration_str,
                   100.0, seg_count, fmt_time(elapsed), "00:00:00", model_name)

    print(f"Transcription complete: {seg_count} segments in {fmt_time(elapsed)} "
          f"using {model_name}", file=sys.stderr)
    return True, seg_count, ""


def main():
    if len(sys.argv) < 4:
        print("Usage: worker.py <mp3-path> <output-txt> <progress-file> [cores]", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    output_path = sys.argv[2]
    progress_path = sys.argv[3]
    cpu_threads = int(sys.argv[4]) if len(sys.argv) >= 5 else 14

    if not os.path.isfile(audio_path):
        print(f"Error: file not found: {audio_path}", file=sys.stderr)
        write_progress(progress_path, "error", error=f"file not found: {audio_path}")
        sys.exit(1)

    duration = get_duration(audio_path)
    if duration:
        print(f"Audio duration: {fmt_time(duration)} ({duration:.0f}s)", file=sys.stderr)

    model_id, device, compute_type, got_gpu, cpu_slot = select_model()
    model_name = f"{model_id}/{device}/{compute_type}"
    print(f"Selected model: {model_name}", file=sys.stderr)

    write_progress(progress_path, "loading_model", model_name=model_name)

    from faster_whisper import WhisperModel

    try:
        try:
            model = WhisperModel(model_id, device=device, compute_type=compute_type, cpu_threads=cpu_threads)
        except Exception as e:
            if "out of memory" in str(e).lower() or "CUDA" in str(e):
                print(f"GPU load failed ({e}), falling back to large-v3/cpu/int8", file=sys.stderr)
                release_gpu_lock()
                got_gpu = False
                model_id, device, compute_type = "large-v3", "cpu", "int8"
                model_name = f"{model_id}/{device}/{compute_type}"
                write_progress(progress_path, "loading_model", model_name=model_name)
                model = WhisperModel(model_id, device=device, compute_type=compute_type, cpu_threads=cpu_threads)
            else:
                raise

        try:
            success, seg_count, err = transcribe(
                model, audio_path, output_path, progress_path, model_name, duration
            )
        except RuntimeError as e:
            if "out of memory" in str(e).lower() or "CUDA" in str(e):
                print(f"OOM during transcription ({e}), retrying with large-v3/cpu/int8",
                      file=sys.stderr)
                del model
                import gc
                gc.collect()
                try:
                    import torch
                    torch.cuda.empty_cache()
                except ImportError:
                    pass
                release_gpu_lock()
                got_gpu = False
                model_id, device, compute_type = "large-v3", "cpu", "int8"
                model_name = f"{model_id}/{device}/{compute_type}"
                write_progress(progress_path, "loading_model", model_name=model_name)
                model = WhisperModel(model_id, device=device, compute_type=compute_type, cpu_threads=cpu_threads)
                success, seg_count, err = transcribe(
                    model, audio_path, output_path, progress_path, model_name, duration
                )
            else:
                write_progress(progress_path, "error", error=str(e))
                raise

        if not success:
            write_progress(progress_path, "error", error=err)
            sys.exit(1)
    finally:
        if got_gpu:
            release_gpu_lock()
        release_cpu_slot(cpu_slot)


if __name__ == "__main__":
    main()
