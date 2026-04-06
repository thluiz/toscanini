#!/usr/bin/env python3
"""
Whisper GPU worker for HermesTools.
Usage: worker.py <mp3-path> <output-txt> <progress-file> [cores]

Dynamic model selection based on free VRAM:
  >= 3.5 GB → large-v3 GPU float16
  >= 2.0 GB → medium GPU float16
  <  2.0 GB → medium CPU int8
  OOM during transcription → retry medium CPU int8
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


def acquire_gpu_lock():
    """Try to acquire GPU lock. Returns True if acquired.
    Checks PID in existing lock — clears stale locks from dead processes."""
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


def select_model():
    import json
    from datetime import datetime
    hour = datetime.now().hour
    gpu_allowed = False
    try:
        schedules = json.load(open("/home/hermes/services/toscanini/data/queue_schedules.json"))
        for w in schedules.get("transcribe", []):
            if w["from"] <= hour < w["to"]:
                gpu_allowed = w.get("gpu", False)
                break
    except Exception:
        # No config file — safe default: CPU only
        print("No scheduler config found, defaulting to CPU", file=sys.stderr)
    if gpu_allowed and acquire_gpu_lock():
        return "large-v3", "cuda", "float16", True
    return "large-v3", "cpu", "int8", False


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


def detect_language(model, audio_path, duration):
    """Sample audio from middle to detect language (avoids intro bias)."""
    if duration and duration > 120:
        offset = max(300, duration * 0.10)
        offset = min(offset, duration - 60)
    else:
        offset = 0

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_path = tmp.name

        cmd = ["ffmpeg", "-i", audio_path, "-ss", str(int(offset)),
               "-t", "30", "-ar", "16000", "-ac", "1", tmp_path, "-y"]
        subprocess.run(cmd, capture_output=True, timeout=30)

        if not os.path.isfile(tmp_path) or os.path.getsize(tmp_path) == 0:
            print("Warning: could not extract sample for language detection, using auto",
                  file=sys.stderr)
            return None

        _, lang_info = model.transcribe(tmp_path, beam_size=1)
        lang = lang_info.language
        prob = lang_info.language_probability
        print(f"Language detected: {lang} (prob={prob:.2f}, sampled at {int(offset)}s)",
              file=sys.stderr)
        return lang
    except Exception as e:
        print(f"Warning: language detection failed ({e}), using auto", file=sys.stderr)
        return None
    finally:
        if tmp_path and os.path.isfile(tmp_path):
            os.unlink(tmp_path)


def transcribe(model, audio_path, output_path, progress_path, model_name, duration):
    """Run transcription and write output. Returns (success, seg_count, error_msg)."""
    detected_lang = detect_language(model, audio_path, duration)

    duration_str = fmt_time(duration) if duration else "?"
    write_progress(progress_path, "transcribing", "00:00:00", duration_str,
                   0.0, 0, "00:00:00", "?", model_name)

    segments, info = model.transcribe(audio_path, language=detected_lang)

    start_time = time.time()
    seg_count = 0
    last_progress_time = 0
    lines = []

    for s in segments:
        line = f"[{fmt_time(s.start)}] {s.text.strip()}"
        lines.append(line)
        seg_count += 1

        now = time.time()
        if now - last_progress_time >= 30:
            elapsed = now - start_time
            pct = (s.end / duration * 100) if duration else 0
            eta_s = ((elapsed / s.end) * (duration - s.end)) if duration and s.end > 0 else 0
            write_progress(progress_path, "transcribing", fmt_time(s.end),
                           duration_str, pct, seg_count, fmt_time(elapsed),
                           fmt_time(eta_s), model_name)
            last_progress_time = now

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

    model_id, device, compute_type, got_gpu = select_model()
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


if __name__ == "__main__":
    main()
