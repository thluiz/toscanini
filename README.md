# Toscanini

Pipeline orchestrator for podcast episode processing on Hermes-PT. Handles the full lifecycle from URL submission to published article with transcription, AI summarization, and automated deployment.

## The name

Arturo Toscanini (1867–1957) was an Italian conductor considered by many the greatest of the 20th century. He was obsessive about precision and coordination — conducting entirely from memory due to severe myopia, demanding that every musician understand the full work rather than just their own part.

The parallel with this project is intentional: Toscanini doesn't improvise. It coordinates independent workers with surgical precision to produce a coherent result.

## Stack

- **Elixir 1.18** + **Phoenix 1.7** + Bandit
- **Oban 2.20** with `Oban.Engines.Lite` (SQLite)
- Ecto + `ecto_sqlite3`, `Req`, `Floki`, `Jason`
- **MCP server** (TypeScript/Bun) for Claude Code integration
- **faster-whisper** (Python) for local GPU/CPU transcription

## Architecture

```
POST /api/orchestrator/jobs { "url": "https://pca.st/episode/..." }
        │
        ▼
   CollectWorker          ← resolves URL, scrapes metadata, downloads MP3, writes JSON sidecar
        │
        ▼
 TranscribeWorker         ← runs whisper locally (GPU/CPU based on scheduler config)
        │
        ▼
  SummarizeWorker         ← calls vox-intelligence with transcript + metadata
        │
        ▼
  AnnotateWorker          ← auto-annotation (only for feeds with auto_annotate)
        │
        ▼
  EnrichTagsWorker        ← adds participants, podcast name, categories as kebab tags
        │
        ▼
  WriteFilesWorker        ← renders JSON → Markdown via vox-pocketcast-json-renderer
        │
        ▼
  GitCommitWorker         ← commits .json + .md to vox-content repo
        │
        ▼
  S3ArchiveWorker         ← archives audio/transcript to cold storage (no-op when disabled)
        │
        ▼
   NotifyWorker           ← sends Telegram notification via GossipGate
```

Toscanini does not publish the site. The Vox site (Hugo + S3 + CloudFront) is built and
deployed by `vox-publish-windows.ps1` in the `vox` repo, which runs hourly on Windows and
picks up whatever was pushed to `vox-content`.

All inter-service HTTP calls use `HERMES_BASE_URL` (nginx gateway — never direct ports).

## API

```bash
# Submit a single episode
curl -X POST http://localhost:8080/api/orchestrator/jobs \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://pca.st/episode/..."}'
# → 202 {"job_id":"...","status":"queued"}
# → 200 {"duplicate":true,...} if already processed

# Submit a batch
curl -X POST http://localhost:8080/api/orchestrator/batch \
  -H 'Content-Type: application/json' \
  -d '{"urls":"https://pca.st/ep1,https://pca.st/ep2"}'

# Check job status
curl http://localhost:8080/api/orchestrator/jobs/:id

# Check batch status
curl http://localhost:8080/api/orchestrator/batch/:id

# Find pipeline by URL
curl http://localhost:8080/api/orchestrator/pipelines/find?url=...

# Prioritize a job (move to front of transcribe queue)
curl -X POST http://localhost:8080/api/orchestrator/pipelines/:id/prioritize

# Publish from pre-processed JSON (skips collect/transcribe/summarize)
curl -X POST http://localhost:8080/api/orchestrator/publish/podcast \
  -H 'Content-Type: application/json' \
  -d '{"path":"2026/03/W11/slug.md","json":{...}}'

# Scheduler config
curl http://localhost:8080/api/orchestrator/scheduler/configs/transcribe
curl -X PUT http://localhost:8080/api/orchestrator/scheduler/configs/transcribe \
  -H 'Content-Type: application/json' \
  -d '{"windows":[{"from":0,"to":9,"limit":3,"gpu":true,"cores":22}]}'

# Health
curl http://localhost:8080/api/orchestrator/health
```

## Transcription

Toscanini runs **faster-whisper** locally via `priv/whisper_worker.py`. Model selection is dynamic:

| Condition | Model | Device | Compute |
|-----------|-------|--------|---------|
| GPU allowed by scheduler + lock acquired + at least 5200 MiB of VRAM free | large-v3 | CUDA | float16 |
| GPU unavailable, not allowed or with less than 5200 MiB of VRAM free | large-v3 | CPU | int8 |
| GPU cooldown open (whisper aborted on the GPU in the last 15 min) | large-v3 | CPU | int8 |
| OOM during GPU transcription | large-v3 | CPU | int8 (auto-fallback, when Python catches it) |

The scheduler controls concurrency, GPU access, and CPU thread count per time window:

```json
{
  "transcribe": [
    { "days": ["sat", "sun"], "from": 0, "to": 24, "limit": 3, "gpu": true, "cores": 14 },
    { "from": 0, "to": 10, "limit": 3, "gpu": true, "cores": 14 },
    { "from": 10, "to": 21, "limit": 2, "gpu": false, "cores": 14 },
    { "from": 21, "to": 24, "limit": 3, "gpu": true, "cores": 14 }
  ]
}
```

- **limit**: max concurrent Oban jobs
- **gpu**: whether GPU is available in this window
- **cores**: CPU threads passed to faster-whisper (default: 14)
- **days** (optional): days the window applies to (`mon`..`sun`); without it the window applies every day. The first window matching hour and day wins, so put day-specific windows first

GPU access is serialized via `/tmp/whisper-gpu.lock` (PID-based, with stale lock detection).

**VRAM check.** large-v3 float16 uses ~5 GB of the 6 GB card, so anything else on the GPU makes it die with `CUDA out of memory`. After taking the GPU lock the worker waits up to 20 s for the previous job to release its VRAM, and if less than `WHISPER_MIN_FREE_VRAM_MB` (default 5200) is free it releases the lock and goes to the CPU instead of starting just to crash. `WHISPER_VRAM_WAIT_SECS` changes the grace period.

**GPU cooldown.** When the whisper process dies on the GPU with exit 134 (`CUDA failed with error out of memory` aborts the whole process, so the Python fallback never runs), `TranscribeWorker` writes `data/gpu_cooldown.json` and snoozes the job instead of spending an attempt. For the next 15 minutes `whisper_worker.py` sends every job to the CPU; after that the next job tries the GPU again.

## Private courses

MP3 files of courses and classes go through the same pipeline but never reach the public site.
They are written to `vox-private-content` (`TOSCANINI_VOX_PRIVATE_DIR`), keep their local MP3
forever (the retention sweep skips anything with `metadata.private`) and use the same layout as
`vox-content`, so `/annotate`, `vox-fetch` and the audio slicing work on them unchanged.

```bash
bun scripts/ingest-private.ts --course "Course name" [--author "Name"] [--dry-run] <file-or-folder>...
```

Run it again whenever new files arrive: copies are skipped when the size already matches and the
server ignores slugs it already processed. `POST /jobs`, `/batch` and the MCP `submit_job`/`submit_batch`
tools also accept `private: true`.

## MCP Integration

The `toscanini-mcp/` directory contains a TypeScript MCP server exposing all orchestrator operations to Claude Code:

| Tool | Description |
|------|-------------|
| `submit_job` | Submit episode URL for processing |
| `submit_batch` | Submit multiple URLs |
| `get_job` / `get_batch` | Poll status |
| `wait_job` / `wait_batch` | Block until completion |
| `find_job_by_url` | Search by episode URL |
| `prioritize_job` | Move to front of queue |
| `publish_podcast` | Publish from pre-processed JSON |
| `get_scheduler_config` | Read queue schedule windows |
| `set_scheduler_config` | Update schedule (limit, gpu, cores) |

## Collectors

| Name | Source | Notes |
|------|--------|-------|
| `pocketcasts` | PocketCasts episode URL | Follows redirects, extracts UUID, scrapes og: + JSON-LD, downloads MP3 |

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `HERMES_BASE_URL` | `http://localhost:8080` | Nginx gateway for all HTTP calls |
| `WHISPER_PYTHON_PATH` | — | Path to Python venv binary |
| `WHISPER_WORKER_PATH` | — | Path to `whisper_worker.py` |
| `WHISPER_LD_LIBRARY_PATH` | — | CUDA/cuDNN library paths |
| `TOSCANINI_VOX_CONTENT_DIR` | — | vox-content git repo path |
| `TOSCANINI_COLLECTED_DIR` | `/home/hermes/collected` | Downloaded MP3 storage |
| `TOSCANINI_DB_PATH` | `data/orchestrator.db` | SQLite database path |
| `GOSSIPGATE_API_KEY` | — | GossipGate notification key |
| `GOSSIPGATE_TARGET` | `toscanini` | GossipGate named destination (Telegram chat) |
| `VOX_BASE_URL` | `https://vox.thluiz.com` | Public site URL for verification |

## Running

```bash
# Via systemd (production)
sudo systemctl start toscanini

# Manually
cd ~/services/toscanini
./start.sh    # sources asdf, runs mix phx.server
```

The systemd unit lives at `deploy/toscanini.service` — see
[`deploy/README.md`](deploy/README.md) for install/upgrade.

## Database

SQLite at `data/orchestrator.db`. Key tables:

- **pipelines** — `id, status, current_step, params, results, error`
- **batches** — `id, total, done, failed, status`
- **batch_items** — `batch_id, position, url, status, pipeline_id, error`
- **oban_jobs** — Oban's job queue (managed by Oban)

## Queues

| Queue | Default Limit | Notes |
|-------|--------------|-------|
| `collectors` | 3 | Parallel episode scraping |
| `transcribe` | 2 | Controlled by scheduler config |
| `git_commit` | 1 | Sequential (avoid conflicts) |
| `default` | 5 | Summarize, enrich, notify, etc. |

## Security TODO

- [ ] **No authentication on any endpoint** — all routes are open including `POST /publish/podcast` (writes files) and `PUT /scheduler/configs/:queue`. Fix: add auth Plug with `X-Api-Key` validation.
- [ ] **LIKE wildcard injection** — `url` param interpolated into LIKE pattern without escaping `%`/`_` (`job_controller.ex:22`). Can suppress legitimate URL processing via false deduplication. Fix: use `json_extract(params, '$.url') = ?` or escape wildcards.
- [ ] **SSRF via user URLs** — URLs from `POST /jobs` passed directly to `Req.get()` with redirect following (`collectors/pocketcasts.ex:56-83,175-183`). Fix: add URL allowlist for `pocketcasts.com`, `pca.st`, and known CDNs.
- [ ] **No rate limiting** — no protection against job submission flooding. Add `PlugAttack` or token-bucket.
