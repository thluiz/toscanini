# Changelog

## [0.2.15] — 2026-07-14

### Rede de segurança dos feeds vira âncora de relógio UTC, configurável em runtime

Antes, o check diário fora da janela quente usava `idle_interval_min` (intervalo
que derivava a partir do último check — sem hora fixa). Agora é uma **âncora de
relógio UTC**: fora da janela quente, o feed é checado 1×/dia na hora UTC
configurada (default **06:00 UTC** = 03:00 BRT — cedo pra já ter episódios
processando de manhã). A hora é **editável em runtime, sem redeploy**, via arquivo
`data/feeds_config.json` (espelha o padrão do scheduler) + endpoint HTTP.

- **`lib/toscanini/feeds_config.ex`** — novo: lê/escreve `data/feeds_config.json`,
  default `safety_hour_utc: 6`, valida 0–23.
- **`lib/toscanini/feeds.ex`** — `due?/2` separa janela quente (hot_interval) da
  rede de segurança (`safety_due?/2`: dispara só quando `now.hour ==
  FeedsConfig.safety_hour_utc()` e ≥12h desde o último check). `idle_interval_min`
  deixa de ser usado.
- **`lib/toscanini_web/controllers/feed_controller.ex`** + rotas — `GET/PUT
  /feeds/config` (`{safety_hour_utc: 0..23}`), muda ao vivo sem restart.

## [0.2.12] — 2026-07-14

### Assinaturas de feed: download automático de novos episódios (PocketCasts)

Novo produtor a montante do pipeline: cadastra-se um podcast e o Toscanini checa
periodicamente por episódios novos, baixando e processando sozinho — sem tocar no
núcleo (Pipeline/Batch). Desenho:

- **Backfill off**: ao assinar grava-se um watermark (`last_published_at`); só
  episódios publicados **depois** entram. Sem isso, um podcast com 1000 episódios
  (ex.: Petit Journal) enfileiraria o catálogo inteiro na primeira checagem.
- **Janela quente**: poll de hora em hora nos dias de publicação (`check_days`),
  com rede de segurança 1×/dia fora deles (pega episódio reagendado/bônus).
- **Conditional GET** (ETag/Last-Modified → `304`): a API PocketCasts honra ambos,
  então checar de hora em hora é quase de graça.
- **UUID armazenado**: short links `pca.st/CODE` são resolvidos uma única vez no
  cadastro; só o `podcast_uuid` (`feed_ref`) é persistido — o polling nunca mais
  toca no short link.

- **`priv/repo/migrations/20260714000001_create_feed_subscriptions.exs`**,
  **`lib/toscanini/feed_subscription.ex`** — tabela/schema de assinaturas.
- **`lib/toscanini/feeds.ex`** — contexto (subscribe com watermark, `due?/2`,
  `check/1` com delta por watermark).
- **`lib/toscanini/workers/feed_sweep_worker.ex`** (cron horário via
  `Oban.Plugins.Cron`), **`lib/toscanini/workers/feed_check_worker.ex`** (checa 1).
- **`lib/toscanini/collectors/pocketcasts.ex`** — extraído
  `fetch_podcast_episodes/2` (conditional GET) + `resolve_podcast_uuid/1`.
- **`lib/toscanini/batches.ex`** — `start_batch/3` partilhado por controller e
  worker. **`lib/toscanini_web/controllers/feed_controller.ex`** + rotas
  `/subscriptions`. **`config/config.exs`** — fila `feeds` + plugin Cron.

## [0.2.11] — 2026-07-13

### Modo livro no publish/scholion (source_url / from_book)

Threading dos sinais de "veio de um livro" até o preset: o endpoint aceita
`source_url` (link Amazon/Kindle) e `from_book`, propagados para o quote-note.
Com isso o preset registra o link como source e compõe um corpo mínimo (só
situa), reduzindo os reds por filler. O portão segue igual (red → draft).

- **`lib/toscanini_web/controllers/scholion_publish_controller.ex`**,
  **`lib/toscanini/workers/scholion_synthesize_worker.ex`**,
  **`lib/toscanini/clients/vox_intelligence.ex`** — repassam `source_url` e
  `from_book` ao preset.

## [0.2.10] — 2026-07-13

### Serialização determinística da nota (JSON do LLM → markdown no Toscanini)

O preset quote-note do vox-intelligence passou a devolver CAMPOS estruturados
(JSON) em vez do markdown pronto; o Toscanini serializa frontmatter + corpo.
Elimina na raiz a classe de bugs de formatação (`---` de fechamento faltando,
aspas mal escapadas) que quebravam o build do Hugo — o YAML agora é gerado por
código, determinístico. Respeita o boundary: vox-intelligence = só LLM,
Toscanini = como publicar.

- **`lib/toscanini/scholion/note.ex`** — novo serializer determinístico (aspas
  corretas por campo: title/sources em duplas, summary/date em simples; `---` de
  fechamento sempre presente; `draft: true` opcional).
- **`lib/toscanini/workers/scholion_synthesize_worker.ex`** — serializa via
  `Note.to_markdown`, roda o ghost-audit sobre a nota, re-serializa com draft se
  `red`. Removidos `extract_title` e `mark_as_draft` (viraram serialização).
- **`lib/toscanini/clients/vox_intelligence.ex`** — `synthesize_quote/1` passa a
  receber os campos estruturados.

## [0.2.9] — 2026-07-13

### ghost-audit red vira `draft: true` (nota versionada) em vez de rascunho perdido

Antes, um verdict `red` parava o pipeline e salvava a nota num diretório à parte
(`scholion-drafts`), fácil de esquecer. Agora a nota é commitada normalmente em
`content/notes/<slug>.md` com `draft: true` no frontmatter — versionada e
corrigível no lugar certo, mas fora do ar (Hugo não builda drafts sem
`--buildDrafts`).

- **`lib/toscanini/workers/scholion_synthesize_worker.ex`** — no `red`, injeta
  `draft: true` no frontmatter e segue o pipeline (write → commit → notify) em
  vez de parar; removido o diretório `scholion-drafts` e o `Pipeline.fail`.
- **`lib/toscanini/workers/scholion_commit_worker.ex`** — mensagem
  `note(draft): <title>` quando draft.
- **`lib/toscanini/workers/notify_worker.ex`** — notificação de draft com os
  findings do ghost-audit (o que corrigir) + o `job_id`.

## [0.2.8] — 2026-07-13

### Feedback acionável quando o ghost-audit barra a nota (red)

Antes, um verdict `red` parava o pipeline mas descartava a nota composta e
notificava só com o resumo — impossível corrigir sem recompor do zero.

- **`lib/toscanini/workers/scholion_synthesize_worker.ex`**:
  - Salva sempre a nota + verdict + findings em `results.scholion_synthesize`
    (inspecionável via `GET /jobs/:id`), inclusive quando o pipeline para.
  - No `red`, grava o rascunho em `TOSCANINI_SCHOLION_DRAFTS_DIR`
    (default `/home/hermes/scholion-drafts/<slug>.md`) para corrigir ou
    abandonar, e a notificação passa a listar os **findings** do ghost-audit
    (o que precisa ser corrigido) + o `job_id`.

## [0.2.7] — 2026-07-13

### Versiona o endpoint `GET /api/orchestrator/status`

O snapshot da fila consumido pela skill `toscanini-status` existia apenas como
hot-patch não versionado no host. Este release traz o código para o repositório.

- **`lib/toscanini/status.ex`** — coleta o snapshot (totals, steps, transcribe,
  executing, falhas recentes na última hora).
- **`lib/toscanini_web/controllers/status_controller.ex`** — `GET /status`.
- **`lib/toscanini_web/router.ex`** — rota `/status`.

## [0.2.6] — 2026-07-13

### Endpoint `POST /publish/scholion` — publica notas de citação no Scholion

Novo endpoint que replica a skill `add-scholion-quote` de forma programática:
recebe `{quote, presumed_author?, context?}`, delega a síntese ao preset
`quote-note` do vox-intelligence (pesquisa de autoria + composição da nota sob
source-or-silence) e publica no repo de conteúdo Scholion.

- **`lib/toscanini_web/controllers/scholion_publish_controller.ex`** — endpoint;
  gera `date` com o relógio real do host e cria o pipeline `scholion_quote`.
- **`lib/toscanini/pipeline/dispatcher.ex`** — pipeline scholion:
  `scholion_synthesize → scholion_write → scholion_commit → notify` (steps com
  chaves próprias; não reusa `write_files`/`git_commit`, que são do podcast).
- **`lib/toscanini/workers/scholion_synthesize_worker.ex`** — chama o preset e
  aplica o portão ghost-audit: verdict `red` interrompe o pipeline; autoria não
  verificada publica com flag na notificação.
- **`lib/toscanini/workers/scholion_write_worker.ex`** — escreve
  `content/notes/<slug>.md` em `TOSCANINI_SCHOLION_DIR` (markdown já pronto do
  preset, sem renderer).
- **`lib/toscanini/workers/scholion_commit_worker.ex`** — commit/push da nota.
- **`lib/toscanini/git.ex`** — novo `Toscanini.Git.commit_and_push/3`, git
  parametrizado por diretório de repo, extraído de `git_commit_worker.ex` (que
  passa a reusá-lo). A auth (deploy key) é resolvida pelo remote do clone via
  `~/.ssh/config` — nenhuma chave no código.
- **`lib/toscanini/clients/vox_intelligence.ex`** — `synthesize_quote/1` e
  `ghost_audit/2`.
- **`lib/toscanini/workers/notify_worker.ex`** — notificação branchada por
  `content_type` (link `scholion.thluiz.com/notes/<slug>/`).
- **`config/runtime.exs`, `deploy/toscanini.service`, `deploy/README.md`** — nova
  env `TOSCANINI_SCHOLION_DIR` e provisão da deploy key de conteúdo Scholion.

## [0.2.5] — 2026-07-02

### Download de áudio: `verify_none` para contornar TLS strict do OTP 27

O Erlang/OTP 27 (`:ssl`) rejeita certos certificados de CDNs de áudio
(ex.: anchor.fm) com `{:tls_alert, {:unsupported_certificate, ...}}` /
`key_usage_mismatch` — certificados que o OpenSSL (curl/Python) aceita
sem problema. Isto fazia o passo `collect` falhar no download do mp3.

- **`lib/toscanini/collectors/pocketcasts.ex`** — `download_audio/3` passa
  `connect_options: [transport_opts: [verify: :verify_none]]` ao `Req.get`.
  A verificação de certificado é desativada APENAS no download do áudio
  (conteúdo público, sem credenciais enviadas). As chamadas de API
  (`resolve_url`, `fetch_episode`) mantêm verificação de certificado total.

## [0.2.4] — 2026-06-30

### Resiliência do collector Pocketcasts a falhas transitórias "não encontrado no feed"

A API PocketCasts (`/podcast/full/{uuid}`) por vezes devolve a lista de
episódios truncada/em cache, fazendo `fetch_episode` não encontrar o
episódio e o pipeline falhar no passo `collect` com "episódio X não
encontrado no feed". O erro é transitório — resubmeter minutos/horas
depois quase sempre funciona. Esta versão recupera automaticamente.

- **`lib/toscanini/collectors/pocketcasts.ex`** — retry em dois níveis
  para o caso "não encontrado no feed":
  - `fetch_episode/2` passa a ser single-shot e devolve
    `{:error, :not_in_feed}` quando o episódio não está na lista. Continua
    a ser usado pela busca especulativa `search_known_podcasts` (rápida,
    sem retry, para não atrasar as sondagens em paralelo).
  - Novo `fetch_episode_with_retry/3` (usado só no caminho principal,
    `fetch_metadata`) faz 2 re-tentativas curtas inline (2s, 4s ≈ máx 6s)
    para absorver blips de segundos. Persistindo, devolve
    `{:error, {:transient_feed, msg}}` (etiquetado) em vez do erro genérico.

- **`lib/toscanini/workers/collect_worker.ex`** — backoff longo sem
  bloquear a fila:
  - Ao receber `{:error, {:transient_feed, msg}}`, em vez de falhar,
    reagenda um novo job `CollectWorker` via `schedule_in` (30min, depois
    1h — `@feed_retry_delays`), contando as tentativas longas no arg
    `feed_retry`. O job atual retorna `:ok` e liberta o slot da fila
    `:collectors` imediatamente — as outras coletas continuam normalmente
    durante a espera (NÃO usa `Process.sleep`, que seguraria o slot).
  - O pipeline fica em status `retrying` durante a janela de backoff (não
    aparece como `failed`) e não dispara notificação de falha no Telegram.
  - Esgotadas as 2 janelas (30min + 1h), falha de vez e notifica.

Efeito: falhas transitórias "não encontrado no feed" recuperam sozinhas e
deixam de exigir resubmissão manual. Links genuinamente mortos (404 na
pca.st) continuam a falhar — só que após ~1h30 em vez de imediatamente.

## [0.2.3] — 2026-05-06

### YouTube collector

- **`lib/toscanini/collectors/youtube.ex`** (new) — collector que aceita
  uma URL de vídeo do YouTube e produz o mesmo par `<slug>.mp3` /
  `<slug>.json` no `collected_dir` que o collector Pocketcasts. Fluxo:
  - **`fetch_metadata/1`** chama `yt-dlp --skip-download --print '%(.{...})j'`
    para extrair só metadata (id, title, channel, channel_id, channel_url,
    uploader, timestamp, upload_date, duration, description, categories,
    tags, webpage_url, thumbnail, language). Pega a última linha do output
    que parse-a como JSON, ignorando warnings que yt-dlp emite em stderr.
  - **`build_meta/2`** normaliza title (strip `\r\n`), gera slug
    (downcase + NFD + strip de tudo que não é `[a-z0-9 ]`, espaços →
    hífen, máx 80 chars), constrói `published` ISO8601 a partir de
    `timestamp` (unix) ou `upload_date` (YYYYMMDD), e mapeia channel/
    uploader para `podcast`/`author` para casar com o schema existente.
    `podcast_show_type` fixo em `"video"`.
  - **`download_audio/3`** chama `yt-dlp -f bestaudio --print
    after_move:filepath` com template `<slug>.%(ext)s`. Extensão real
    fica a cargo do yt-dlp (geralmente webm/Opus). Antes de baixar,
    `find_cached_audio/2` procura por `<slug>.{webm,m4a,opus,mp4,mp3,
    ogg,wav}` e reusa se existir — re-runs não rebaixam.
  - **`write_json/2`** faz merge com JSON existente: preserva
    `description`/`lang` se já presentes (output de summarize não é
    sobrescrito em re-runs), mas atualiza `metadata` com fresh values
    não-nil. Marca `metadata.source = "youtube"`.

- **`lib/toscanini/pipelines.ex`** — registro de `"youtube" =>
  Toscanini.Collectors.Youtube` no map `@collectors`. Pipelines agora
  podem ser criados com `collector: "youtube"`.

- **`lib/toscanini/workers/transcribe_worker.ex`** — `run_transcription/4`
  agora lê `collect["audio"] || collect["mp3"]`. O collector YouTube
  emite a chave `audio` (extensão variável); Pocketcasts continua
  usando `mp3`. Backwards-compatible.

### Configuração

- **`TOSCANINI_YTDLP_BIN`** (env, default `/home/hermes/.local/bin/yt-dlp`)
  — caminho do binário yt-dlp. yt-dlp tem que estar instalado no host
  e ter ffmpeg disponível no `$PATH` para extração de áudio.

### Tests

- **`test/toscanini/collectors/youtube_test.exs`** (new) — cobertura
  de `build_meta/2` (normalização de título, slugify com unicode,
  parsing de `timestamp` vs `upload_date`, fallback de campos) e
  `write_json/2` (merge preservando description/lang existentes,
  `source = "youtube"`).


## [0.2.2] — 2026-04-07

### Pipeline deduplication by slug

- **`lib/toscanini/pipeline.ex`** — new `find_duplicate_by_slug/2` and
  `mark_duplicate/2`. `find_duplicate_by_slug/2` runs a SQL query over
  the `pipelines` table (`json_extract(results, '$.collect.slug')`) to
  find any pipeline with the same slug that is `running` or `done`,
  excluding the current one. `mark_duplicate/2` marks the current
  pipeline as `done` with `results.duplicate_of` + `results.skipped_reason
  = "duplicate_slug"`, and — if the pipeline is part of a batch —
  enqueues a `BatchAdvanceWorker` to move the batch forward.
- **`lib/toscanini/workers/collect_worker.ex`** — after a successful
  collect step, looks up the slug in existing pipelines. If a duplicate
  exists and `params["force_retranscribe"]` is not `true`, marks the
  current pipeline as duplicate and skips downstream work. Otherwise
  advances normally.

**Why:** avoids re-transcribing and re-publishing episodes that were
already processed under a different URL (e.g., the same episode
submitted via different PocketCasts share links). Saves GPU time and
prevents duplicate outputs in `vox-content`.

### Pocketcasts collector — resilience improvements

- **`lib/toscanini/collectors/pocketcasts.ex`**
  - New `resolve_or_search/1` wraps the original redirect + og:url
    resolution path. When that fails but the input URL contains a
    single UUID (ambiguous between podcast and episode), falls back to
    `search_known_podcasts/1` which reads all JSONs under
    `collected_dir`, collects every distinct `metadata.podcast_uuid`,
    and tries the episode UUID against each one in parallel (`Task.async_stream`,
    `max_concurrency: 10`, `timeout: 15_000`, `on_timeout: :kill_task`).
    First match wins and is logged.
  - `download_audio/2` — `max_redirects` bumped from **5 → 10**. Some
    CDN chains exceeded 5 hops and were failing mid-download.

**Why:** PocketCasts share URLs occasionally redirect to pages that
don't expose the podcast UUID in their `og:url`, leaving only an
episode UUID. Before, collection would fail; now Toscanini can locate
the parent podcast by probing podcasts it already knows.

### New endpoint: `POST /ingest/local`

- **`lib/toscanini_web/controllers/ingest_local_controller.ex`** (new)
  — accepts `{slug, json, duration_secs, source_url?}` and ingests an
  episode whose audio (`<slug>.mp3`) is already present in
  `collected_dir`. Writes the provided JSON beside the MP3, creates a
  fresh pipeline row with `collector: "local_ingest"` and
  `current_step: "collect"`, and kicks it into the dispatcher. Returns
  `202 Accepted` with the job id. Responds `422` if the MP3 is missing
  and `400` on missing required fields.
- **`lib/toscanini_web/router.ex`** — route `POST /ingest/local` →
  `IngestLocalController.create/2` added to the API scope.
- **`lib/toscanini/workers/write_files_worker.ex`** — now passes
  `slug: slug` to `VoxPocketcastJsonRenderer.render/2`. (With the
  renderer change below this option is no longer consumed, but the
  call site remains forward-compatible.)

**Why:** enables bypassing the PocketCasts collector entirely when an
episode has been downloaded or transcribed via an external tool —
useful for manual rescues of episodes that PocketCasts doesn't resolve.

### VoxPocketcastJsonRenderer: metadata sections moved to Hugo footer

The episode metadata previously emitted inline in the generated markdown
(`## Dados do Episódio` / `## Dados do Podcast` / `## Episode Info` /
`## Podcast Info`) is now rendered by the Vox-Hugo `episode-footer`
partial, which reads the sibling `.json` sidecar at build time. This
eliminates content/template duplication and centralises all
podcast/episode metadata display in the theme.

- **`lib/toscanini/vox_pocketcast_json_renderer.ex`**
  - Removed `render_metadata/3` and its section header — no longer
    emits `## Dados do Episódio` / `## Dados do Podcast` /
    `## Episode Info` / `## Podcast Info` blocks or the nested
    `### Referências` / `### References` metadata subsection containing
    the PocketCasts URL.
  - Removed `render_json_footer/2` — no longer appends the hardcoded
    `[Dados adicionais e transcrição](slug.json)` /
    `[Additional data and transcript](slug.json)` link at the bottom of
    every episode. The Hugo footer reconstructs this link from the page
    permalink.
  - Removed the now-unused `add/2` helper.
  - `render/2` signature: `opts` → `_opts` (the `:slug` option is no
    longer consumed, but the call in `WriteFilesWorker` still passes
    it for forward compatibility).

**Why:** the old approach meant (a) every published episode carried the
same metadata block in content form, (b) editing the presentation
required bulk-rewriting thousands of markdown files, and (c) path
fragility in the JSON pointer link forced a workaround in Hugo's
`render-link.html`. Moving metadata to the Hugo template makes it
editorial-free, keeps content focused on the episode itself, and allows
a single place to update presentation across the entire archive.

**Note:** new episodes will be emitted clean from this commit onward.
Existing episodes in `E:\vox-content` still contain the old sections —
a follow-up cleanup pass removes them from the ~1841 historical MDs.

### Test infrastructure: renderer unit tests

- **`test/toscanini/vox_pocketcast_json_renderer_test.exs`** (new) —
  20 ExUnit tests covering `VoxPocketcastJsonRenderer.render/2`. Two
  fixture-driven `describe` blocks (one PT, one EN) verify the overall
  output shape (frontmatter → H1 → editorial sections), the presence of
  expected sections (`## Resumo`/`## Summary`, `## Linha do Tempo`/
  `## Topic Timeline`, `## Indicações`/`## Recommendations`), and the
  *absence* of all four metadata blocks plus the legacy hardcoded JSON
  pointer link. A third `describe` covers minimal-input edge cases and
  the forward-compatible `:slug` option. Tests run `async: true` since
  the renderer is pure.
- **`test/fixtures/renderer/t12exxnov-republica.json`** (new) — small
  PT episode fixture (~6 KB) captured from
  `E:\vox-content\2021\11\W46`, transcript field stripped to keep the
  fixture lightweight. Real `recommendations` (with `leis` category)
  and timeline data exercise the full rendering pipeline.
- **`test/fixtures/renderer/friday-refill-give-tomorrowyou-advice-from-today.json`**
  (new) — small EN episode fixture (~6 KB) captured from
  `E:\vox-content\2021\08\W31`, transcript stripped. Includes a single
  participant and a `practices` recommendations category.
- **`config/test.exs`** — added `pool: Ecto.Adapters.SQL.Sandbox` to
  the `Toscanini.Repo` config. The previous test config left the pool
  unset, which made `test_helper.exs`'s `Sandbox.mode/2` call blow up
  with `cannot invoke sandbox operation with pool DBConnection.ConnectionPool`
  on any `mix test` invocation. With this fix the entire test suite
  (including the new renderer tests and the pre-existing
  `error_json_test.exs`) is runnable.


## [0.2.1] — 2026-04-06

### Bug fix: scheduler usava UTC em vez de hora local

- **`transcribe_worker.ex`** — corrigido `Time.utc_now().hour` → `NaiveDateTime.local_now().hour` em `get_current_cores/1` e `apply_queue_concurrency/1`. Bug pré-existente desde v0.2.0 que causava desfasamento de 1h (WEST = UTC+1), permitindo 2 jobs GPU simultâneos. (`DateTime.now!("Europe/Lisbon")` não funciona sem a lib `tzdata`)
- **`priv/queue_schedules.json`** — template actualizado: cores 12→14 na janela 9h-20h (alinhado com runtime)
- **`data/queue_schedules.json`** — removido do git (runtime, sobrescrito pela API). Adicionado ao `.gitignore`

### Bug fix: race condition no GPU lock

- **`priv/whisper_worker.py`** — quando múltiplos workers detectavam stale lock (PID morto) simultaneamente, todos faziam `os.replace` e achavam que tinham o lock → 2 jobs GPU ao mesmo tempo. Corrigido: `unlink` + `O_CREAT|O_EXCL` garante que só um worker ganha o lock

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
