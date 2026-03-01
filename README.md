# Toscanini

Pipeline orchestrator for long-running async workflows on HermesTools.

## The name

Arturo Toscanini (1867–1957) was an Italian conductor considered by many the greatest of the 20th century. He was obsessive about precision and coordination — conducting entirely from memory due to severe myopia, demanding that every musician understand the full work rather than just their own part.

The parallel with this project is intentional: Toscanini doesn't improvise. It coordinates independent workers with surgical precision to produce a coherent result.

## Stack

- Elixir 1.18 + Phoenix 1.7 + Bandit
- Oban 2.20 with `Oban.Engines.Lite` (SQLite)
- Ecto + `ecto_sqlite3`, `Req`, `Floki`, `Jason`

## Architecture

```
POST /api/orchestrator/jobs
        │
        ▼
   CollectWorker          ← scrapes HTML, downloads MP3, writes {slug}.json sidecar
        │
        ▼
TranscribeSubmitWorker    ← submits MP3 to whisper-api
        │
        ▼
TranscribePollWorker      ← polls whisper every 10–30s, writes transcript into JSON
        │
        ▼
   SummarizeWorker        ← calls vox-intelligence with metadata + transcript + timestamps
        │
        ▼
    NotifyWorker          ← sends Telegram notification via GossipGate
```

All inter-service HTTP calls use `HERMES_BASE_URL` (nginx as source of truth — never direct ports).

## API

```bash
# Submit a job
curl -X POST http://localhost:8080/api/orchestrator/jobs \
  -H 'Content-Type: application/json' \
  -d '{"content_type":"podcast","collector":"pocketcasts","params":{"url":"https://pca.st/episode/..."}}'
# → 202 {"job_id":"...","status":"queued"}

# Check status
curl http://localhost:8080/api/orchestrator/jobs/:id

# Health
curl http://localhost:8080/api/orchestrator/health
```

## Collectors

| Name | Source | Notes |
|------|--------|-------|
| `pocketcasts` | PocketCasts episode URL | Scrapes og: + JSON-LD, downloads MP3 |

## JSON sidecar

Each collected episode produces `{slug}.json` alongside `{slug}.mp3`:

```json
{
  "version": 1,
  "metadata": {
    "podcast": "...",
    "author": "...",
    "published": "2026-02-19",
    "duration": "01:52:00",
    "uuid": "episode-uuid",
    "source_url": "https://pca.st/episode/...",
    "source": "pocketcasts"
  },
  "transcript": null
}
```

`transcript` starts as `null` and is filled by `TranscribePollWorker`. The summarize step merges the LLM result back into this file.

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `HERMES_BASE_URL` | `http://localhost:8080` | Nginx gateway |
| `MIX_ENV` | `dev` | Mix environment |

## Running

```bash
# Via systemd (production)
systemctl start hermes-orchestrator

# Manually
cd ~/services/hermes_orchestrator
./start.sh
```

## Roadmap

- [ ] `IngestWorker` — publish processed JSON to vox-ingest
- [ ] `WaitFor` + `POST /respond/:token` — async approval flows
- [ ] Collectors: YouTube, web articles
- [ ] OpenClaw skill `job-answer` integration
