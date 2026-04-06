# Changelog

## [0.2.1] — 2026-04-06

### Bug fix: scheduler usava UTC em vez de hora local

- **`priv/whisper_worker.py`** — `datetime.utcnow()` já tinha sido corrigido para `datetime.now()` num hotfix anterior
- **`transcribe_worker.ex`** — corrigido `Time.utc_now().hour` → `DateTime.now!("Europe/Lisbon").hour` em `get_current_cores/1` e `apply_queue_concurrency/1`. Bug pré-existente desde v0.2.0 que causava desfasamento de 1h (WEST = UTC+1), permitindo 2 jobs GPU simultâneos
- **`priv/queue_schedules.json`** — template actualizado: cores 12→14 na janela 9h-20h (alinhado com runtime)
- **`data/queue_schedules.json`** — removido do git (runtime, sobrescrito pela API). Adicionado ao `.gitignore`

All notable changes to Toscanini are documented in this file.

## [0.2.0] — 2026-03-15

Major refactoring: Toscanini now owns the full lifecycle from transcription through publication, removing all external service dependencies.

### Transcription overhaul

- **Removed whisper-api dependency** — no longer submits jobs to the HTTP whisper-api service (port 8003). Toscanini now runs `faster-whisper` directly as a subprocess via `priv/whisper_worker.py`
- **Replaced `TranscribeSubmitWorker` + `TranscribePollWorker`** with a single `TranscribeWorker` that manages the full transcription lifecycle: model selection, GPU lock acquisition, progress tracking, OOM fallback
- **Dynamic model selection** — reads `priv/queue_schedules.json` at runtime to decide GPU vs CPU. GPU uses `large-v3/cuda/float16`, CPU uses `large-v3/cpu/int8`
- **GPU lock** — file-based mutex (`/tmp/whisper-gpu.lock`) with PID checking and stale lock recovery. Only one GPU transcription at a time
- **OOM auto-fallback** — if GPU runs out of memory (load or mid-transcription), automatically retries with CPU/int8
- **Language detection** — samples audio from ~10% offset (avoids intro jingles) for more accurate language detection

### Scheduler system

- **Time-window based scheduling** — `priv/queue_schedules.json` defines per-queue concurrency windows by hour of day
- **Per-window parameters**: `limit` (max concurrent jobs), `gpu` (allow GPU in this window), `cores` (CPU threads for whisper, default 14)
- **Runtime API** — `GET/PUT /scheduler/configs/:queue` to read and update config. Changes apply immediately via `Oban.scale_queue`
- **Worker-level enforcement** — `TranscribeWorker` reads current window config on each job start, ensuring correct concurrency even across Oban restarts

### Publishing pipeline

Previously Toscanini stopped at summarization and relied on external tools for publishing. Now handles the full flow:

- **`EnrichTagsWorker`** — deterministic (no AI): extracts participants from summary, adds podcast name and categories as kebab-case tags. Identifies hosts (2+ episodes in same podcast) vs guests
- **`WriteFilesWorker`** — renders JSON sidecar to Markdown via `VoxPocketcastJsonRenderer`. Generates frontmatter (title, date, tags, lang, description, aliases), sections (Resumo/Summary, Anotações, Indicações/Recommendations, Linha do Tempo/Timeline, Dados do Episódio/Podcast, Transcrição). Writes both `.json` and `.md` to vox-content directory
- **`GitCommitWorker`** — commits `.json` + `.md` to the vox-content git repo. Sequential queue (limit 1) to avoid conflicts
- **`VoxPublishWorker`** — runs vox-publish script (Quartz build + S3 sync + CloudFront invalidation). Sequential queue (limit 1)
- **`VerifyUrlWorker`** — HTTP HEAD to `VOX_BASE_URL/{path}` to confirm the article is live (retries on 404)
- **`FacebookCacheRefreshWorker`** — `POST` to Facebook Graph API (`?id=URL&scrape=true`) to warm og:tags for link previews. Configurable delay via `FACEBOOK_REFRESH_DELAY` (default 120s after publish)

### Job management

- **Deduplication** — `POST /jobs` checks if URL was already processed (`status=done`). Returns `200 {duplicate: true}` instead of creating a new pipeline
- **Find by URL** — `GET /pipelines/find?url=...` returns pipeline_id, status, current_step
- **Prioritize** — `POST /pipelines/:id/prioritize` sets Oban job priority to 0 (front of queue)
- **Publish from JSON** — `POST /publish/podcast` accepts pre-processed JSON and starts at `enrich_tags`, skipping collect/transcribe/summarize. Used for manual corrections and re-publishes
- **Flat params** — job submission now accepts `{"url":"..."}` directly (flat), content_type and collector are schema fields rather than nested params

### PocketCasts collector improvements

- **UUID extraction** — tries URL path first (`/episode/{uuid}`), then follows redirects via `Location` header, falls back to `og:url` from page HTML
- **Non-ASCII redirect handling** — percent-encodes Latin-1 bytes in `Location` headers (some CDNs return raw bytes)
- **Redirect following** — manual redirect loop with `redirect: false` on Req (Req 0.5.x `%Response{}` has no `url` field)

### MCP tools (new)

- `get_scheduler_config` / `set_scheduler_config` — runtime queue scheduling with cores parameter
- `find_job_by_url` — search pipelines by episode URL
- `prioritize_job` — move job to front of transcribe queue
- `publish_podcast` — publish from pre-processed JSON

### Configuration (new env vars)

- `WHISPER_PYTHON_PATH` — Python venv binary for whisper
- `WHISPER_WORKER_PATH` — path to `whisper_worker.py` (now `priv/whisper_worker.py`)
- `WHISPER_LD_LIBRARY_PATH` — CUDA/cuDNN library paths
- `TOSCANINI_VOX_CONTENT_DIR` — vox-content git repo
- `TOSCANINI_VOX_PUBLISH_BIN` — vox-publish script
- `VOX_BASE_URL` — public Vox URL for verification
- `FACEBOOK_APP_TOKEN` — `APP_ID|APP_SECRET` for og: cache refresh
- `FACEBOOK_REFRESH_DELAY` — seconds to wait before Facebook refresh (default 120)

### Pipeline steps (full)

```
collect → transcribe → summarize → enrich_tags → write_files
→ git_commit → vox_publish → verify_url → facebook_cache_refresh → notify
```

---

## [0.1.0] — 2026-03-01

Initial release of Toscanini orchestrator.

### Architecture

- **Elixir 1.18 + Phoenix 1.7 + Bandit** web server
- **Oban 2.20** with `Oban.Engines.Lite` (SQLite) for job scheduling
- **Ecto + ecto_sqlite3** for persistence
- **Req** for HTTP client, **Floki** for HTML parsing

### Pipeline

```
collect → transcribe_submit → transcribe_poll → summarize → notify
```

- **CollectWorker** — PocketCasts collector: resolves share URLs, scrapes metadata via og: tags and JSON-LD, downloads MP3, writes JSON sidecar with metadata
- **TranscribeSubmitWorker** — submits MP3 to external whisper-api HTTP service (port 8003), receives job_id
- **TranscribePollWorker** — polls whisper-api every 10-30s until transcription completes, writes transcript back to JSON sidecar
- **SummarizeWorker** — sends transcript + metadata to vox-intelligence API for AI-powered summarization (summary, timeline, recommendations, annotations)
- **NotifyWorker** — sends Telegram notification with episode title and link via GossipGate

### External dependencies

- **whisper-api** (Bun/HTTP service on port 8003) — managed transcription queue, GPU selection, and progress tracking
- **vox-intelligence** — AI summarization via nginx gateway
- **GossipGate** — Telegram notifications via nginx gateway

### API

- `POST /api/orchestrator/jobs` — submit single episode (202 response)
- `GET /api/orchestrator/jobs/:id` — poll job status and results
- `POST /api/orchestrator/batch` — submit multiple URLs for sequential processing
- `GET /api/orchestrator/batch/:id` — poll batch status
- `GET /api/orchestrator/health` — health check

### MCP server

TypeScript/Bun MCP server (`toscanini-mcp/`) exposing:
- `submit_job`, `submit_batch` — job submission
- `get_job`, `get_batch` — status polling
- `wait_job`, `wait_batch` — blocking poll until completion

### Infrastructure

- **systemd service** — `toscanini.service` with asdf-sourced start script
- **nginx integration** — all inter-service HTTP via `HERMES_BASE_URL` gateway (never direct ports)
- **SQLite database** — `data/orchestrator.db` with pipelines, batches, batch_items tables
