# Changelog

## [0.2.58] — 2026-11-20

### Duração divergente do feed vira erro específico, com override

A 0.2.57 passava a confiar sempre no áudio medido, o que tirava o controle de qualidade do download: um MP3 cortado
passaria calado. Agora cada checagem tem sua referência.

- **Checagem do download** (`AudioDuration.compare/2`, no início do `TranscribeWorker`) — o feed é a referência.
  Áudio abaixo de 90% do feed (download incompleto?) ou acima de 3× (arquivo errado?) falha o pipeline antes do
  whisper com `duração divergente: áudio Xs, feed Ys (Z%)` e avisa pelo GossipGate. Reenviar com
  `accept_duration_mismatch: true` força o processamento (o reenvio baixa de novo, o que já corrige um download
  cortado). Tolerância calibrada numa varredura de 1134 episódios coletados: anúncios dinâmicos deixam o áudio até
  ~1,7× o feed, arquivos mono 2×; áudio menor que o feed só no #224.
- **Checagem da transcrição** — o áudio medido segue como referência (`reconcile/2`), já que é o que o whisper
  transcreveu. Sem `ffprobe`, vale o metadado e nada bloqueia.
- Pipelines anteriores à 0.2.57 usam `collect.duration_secs` como valor do feed.
- Divergência dentro da faixa aceita vai para o log em nível `info` (era `warning`).
- `reject_degenerate/2` virou `reject/3`, com o título do aviso como parâmetro.
- **MCP `submit_job`** aceita `accept_duration_mismatch` (antes o tool só repassava `url`, `collector`,
  `force_retranscribe` e `private`). `mcp/mcp.ts` sincronizado com a cópia em produção
  (`services/toscanini-mcp/mcp.ts`), que tinha as descrições de `save_failed` da 0.2.53 fora do git.

## [0.2.57] — 2026-11-20

### Duração medida no áudio, não no metadado do feed

O Filosofia Pop #224 foi rejeitado duas vezes como "transcrição truncada: termina em 3378s de 202740s (2%)". A
transcrição estava completa: a API do Pocket Casts devolve `duration: 202740` para um MP3 de 3379s (provável "56:19"
lido como h:m na origem). O mesmo número fazia o `valid_transcript?` exigir 60× os caracteres e iria para o JSON
publicado como episódio de 56h.

- **`Toscanini.AudioDuration`** — mede o arquivo com `ffprobe` (timeout 30s); se falhar, usa o metadado. Divergência
  acima de 10% entre os dois vai para o log (`[AudioDuration] ...`).
- **Collector Pocket Casts** — mede o MP3 logo após o download. `duration_secs` passa a ser o valor medido;
  o da API fica em `duration_secs_meta` (resultado do `collect`).
- **`TranscribeWorker`** — mede de novo antes do `valid_transcript?` e do `TranscriptCheck`, o que cobre pipelines
  coletados antes desta versão e qualquer outro collector. Limiares do `TranscriptCheck` inalterados.
- Testes: `audio_duration_test.exs` (inclui medição de um MP3 gerado com `ffmpeg`).

## [0.2.56] — 2026-11-19

### Janela quente só para dias fixos ou programa diário; rede de segurança 2×/dia

Janela quente (checagem horária) só faz sentido para quem publica em 1 a 3 dias fixos da semana, ou para programa
diário. O resto fica só com a rede de segurança, que agora roda duas vezes por dia.

- **`check_days` vazio = sem janela quente** — antes era "hot sempre ligado" (checagem de hora em hora todo dia);
  agora a assinatura só é checada nas horas da rede de segurança.
- **`infer_check_days/2`** — programa diário (≥ 4 episódios/semana na amostra) fica quente nos dias em que publicou
  nos últimos 28 dias (ex.: seg–sex). Fora isso, a regra dos dias dominantes de antes, mas resultado com mais de 3
  dias vira `[]` (antes o corte em 3 podia passar para 4–5 com os vizinhos de drift).
- **Feed dormente** — sem episódio há mais de 60 dias, o subscribe não infere janela quente
  (`Feeds.schedule_for/3`, `Feeds.dormant?/2`), qualquer que tenha sido a cadência antiga.
- **`FeedsConfig.safety_hours_utc`** — lista de horas UTC da rede de segurança, default `[3, 15]` (antes uma hora
  só, `safety_hour_utc`, default 6). A chave antiga continua aceita no `PUT /feeds/config` e no arquivo
  `data/feeds_config.json`, e vira `[h]`. O gap mínimo desde o último check passa a ser metade do menor intervalo
  entre âncoras (`[3, 15]` → 6h; antes 12h fixo, que com âncoras a 12h de distância pulava a segunda checagem por
  segundos).
- **`SUBSCRIPTIONS.md`** — `check_days` vazio sai como `nenhum` (antes `sempre`); o parse aceita os dois.
- **MCP `get/set_feeds_config`** — `safety_hours_utc` (lista); `safety_hour_utc` fica como legado.
- Testes: `feeds_test.exs`, `feeds_config_test.exs`, `feeds/backup_test.exs`.

## [0.2.55] — 2026-11-19

### Inscrição em canais do YouTube

Canais do YouTube agora são assinados como os podcasts do Pocket Casts: cada vídeo longo novo entra sozinho no
pipeline (collector `youtube`) e sai publicado no Vox. Sem backfill (watermark no vídeo mais recente) e
`auto_annotate` desligado por padrão.

- **`Collectors.YoutubeFeed`** — lê o Atom da playlist de vídeos longos (`UULF<id>`), então Shorts (só no feed
  `channel_id=UC…`) e lives (playlist `UULV…`) ficam de fora. Nome do canal vem de `<author><name>` (o `<title>` do
  feed é literalmente `Videos`). Parse com `:xmerl` (adicionado a `extra_applications`), sobre os bytes UTF-8 crus.
  O feed não manda `ETag`/`Last-Modified`; o GET condicional fica só por simetria.
- **Resolução do canal** — `/channel/UC…` sai direto; `@handle`, `/c/`, `/user/` e URLs de vídeo (`watch?v=`,
  `youtu.be`, `/live/`) vão pelo `yt-dlp --flat-playlist`, imprimindo `playlist_channel_id` e `channel_id` (em modo
  flat, página de canal só preenche o primeiro e vídeo só o segundo).
- **Estreias** — aparecem no feed antes de o vídeo existir. `YoutubeFeed.upcoming?/2` (`--print live_status` com
  `--ignore-no-formats-error`) e o check para no primeiro vídeo `is_upcoming`/`is_live`: o watermark só avança até
  o último submetido, segurando também os vídeos posteriores até a estreia ir ao ar. Fail-open: erro/timeout do
  yt-dlp conta como não-estreia, pra não congelar o canal em silêncio.
- **`Feeds`** — `subscribe` infere `source: "youtube"` de URL youtube.com/youtu.be ou `feed_ref` `UC…`;
  `prime_watermark/3` e `check/2` despacham por source (fetch, URL do episódio, collector). `rss` deixa de ficar
  sem watermark no subscribe (cai no caminho de falha do fetch, watermark = agora). `FeedSubscription` aceita
  `"youtube"`.
- **Dedup no job avulso** — `submit_single` não cria pipeline se já existe um não-falho com a mesma URL (vídeo ou
  episódio submetido à mão pouco antes do check). Vale também pro Pocket Casts.
- **MCP `subscribe_feed`** — descrição cobre YouTube; `source` opcional repassado ao `POST /subscriptions`.
- Testes: `test/toscanini/collectors/youtube_feed_test.exs`, `test/toscanini/feeds/youtube_check_test.exs`
  (fixture `test/support/fixtures/youtube_feed.xml`).

## [0.2.54] — 2026-11-18

### Citação sem fonte verificável vira rascunho

Em 2026-11-17, 8 citações vindas de tweets (`POST /publish/scholion` com `source_url` = tweet) saíram publicadas com
atribuição a livros inventada pelo preset `quote-note`. A correção principal é no vox-intelligence 1.9.0 (tweet sempre
em `sources`, obra só com fonte consultada, nada atribuído ao solicitante); aqui, o que o preset não conseguir
sustentar não vai ao ar.

- **`ScholionSynthesizeWorker.draft_reason/2`** — além de ghost-audit red (`"audit_red"`), `authorship.verified ==
  false` (`"unverified"`) também serializa a nota com `draft: true`. `results.scholion_synthesize.draft_reason`
  guarda o motivo; o commit continua `note(draft): ...`.
- **Aviso no Telegram** — rascunho por autoria diz "autoria sem fonte verificável → salva como DRAFT", com as
  `authorship.notes`. O aviso "autoria não verificada" na nota publicada sai (ela não publica mais).
- Testes: `test/toscanini/scholion_draft_reason_test.exs`.

## [0.2.53] — 2026-11-18

### Webclip: save retomável sem novo compose, save na frente dos composes, aviso só na última tentativa

- **Save que esgota as tentativas estaciona (`save_failed`)** — antes, timeout/502 no save nas 3 tentativas
  falhava o pipeline, e reenviar refazia o compose (custo LLM). Agora `Webclip.classify_save/2` devolve
  `{:park, "save_failed", ...}` para erro de transporte ou `retryable` na última tentativa; o park guarda
  `operation_id` e `expires_at` (o aviso no Telegram diz até quando a operação vale). Erro não-retryable continua
  falhando.
- **Retomar no passo save** — `Webclip.resume_step/4` decide onde o webclip retoma: estacionado `save_failed` (ou
  failed em `webclip_save`, caso dos pipelines anteriores a esta versão), com `operation_id` em
  `results.webclip_compose` e sem `text`/`related_notes` novos → `webclip_save`, com a mesma operação; o resto →
  `webclip_compose`, como antes. Operação expirada responde `operation_not_found` e o save já volta ao compose
  sozinho. `POST /parked/:id/resume` (MCP `resume_parked`) aceita também um webclip `failed` em `webclip_save`;
  limpa o `error`.
- **Save na frente na fila `webclip: 1`** — `Dispatcher.priority/1`: compose entra com prioridade Oban 1, todo o
  resto com 0. Com N URLs enfileiradas, o save de cada nota roda logo depois do próprio compose, em vez de esperar
  os N composes.
- **Telegram só na última tentativa** — `ObanNotifier` deixa de mandar "❌ Toscanini — falha no pipeline" a cada
  tentativa que falha (1/3, 2/3); avisa só quando `attempt >= max_attempts`. Vale para todos os workers.
- toscanini-mcp (fora do git): descrições de `list_parked`/`resume_parked` citam `save_failed`.
- Testes: `webclip_test.exs` (classify_save, resume_step, priority, last_attempt?) e `webclip_controllers_test.exs`
  (resume no save: fila, prioridade, failed retomável; resume com texto recompõe com prioridade 1).

## [0.2.52] — 2026-11-18

### YouTube volta a baixar áudio: player clients escolhidos pelo yt-dlp

O lote `ea744a8d` falhou no `kU-t1qsEbqk` com `HTTP Error 403`. No HermesTools o yt-dlp estava em 2026.06.09 e o
collector fixava `--extractor-args youtube:player_client=web_embedded,android_vr` (contorno de junho). Com o yt-dlp
2026.10.21 nenhum dos dois devolve formato de áudio para esse vídeo: `web_embedded` cai em "playback on other
websites has been disabled", `android_vr` exige GVS PO token. Os clients padrão do yt-dlp, com o deno resolvendo o
desafio JS, devolvem o áudio (formato 251).

- **`Collectors.Youtube` não fixa mais player clients** — o yt-dlp escolhe. Override pontual via
  `TOSCANINI_YTDLP_EXTRACTOR_ARGS` (ex.: `youtube:player_client=default,mweb`), que vira `--extractor-args`.
- **`deploy/setup-host.sh` atualiza o deno** (`deno upgrade`) quando ele já está instalado, em vez de pular.
- Host atualizado: yt-dlp 2026.10.21, deno 2.9.8. O PATH do `toscanini.service` já incluía `~/.deno/bin`
  (`[debug] JS runtimes: deno-2.9.8` num collect rodado com o env do serviço).
- Um 403 esporádico de mídia ainda aparece; o `CollectWorker` tenta 3 vezes.

## [0.2.51] — 2026-11-18

### Espelho das assinaturas de feed em SUBSCRIPTIONS.md e restauração

O banco não tem backup e `feed_subscriptions` é a única tabela que é configuração (as demais são fila e histórico).

- **`Toscanini.Feeds.Backup`** — reescreve `SUBSCRIPTIONS.md` (raiz do repo) quando uma assinatura é criada, alterada ou removida (`Feeds.subscribe/2`, `update_subscription/2`, `delete_subscription/1`). Escrita atômica, sem regravar se o conteúdo não mudou; falha de escrita só vira log e não derruba a operação. O watermark fica fora do arquivo. O commit é manual.
- **`mix toscanini.restore_subscriptions`** (`--file`, `--dry-run`) — recria as assinaturas a partir do arquivo, pulando as que já existem. Sobe só o Repo e o cliente HTTP (sem Oban nem endpoint). Cada uma passa por `Feeds.subscribe/2`, que grava um watermark novo (episódio mais recente, sem backfill).
- `Feeds.subscribe/2` ganha `opts` (`sync: false` pula a escrita do arquivo, usado na restauração).
- Testes: `test/toscanini/feeds/backup_test.exs`. O ambiente de teste desliga a escrita (`:subscriptions_md_path` nil).
- Precisa de restart do serviço para valer.

## [0.2.50] — 2026-11-17

### Webclip red vira rascunho no vault

Até aqui um webclip com ghost-audit red só estacionava: a captura e a nota composta ficavam apenas na operação
pendente do webclipper, que a varredura apaga depois de 24h. Se a página saísse do ar nesse intervalo, perdia-se.

- **Rascunho antes de estacionar** — com verdict red, o `WebclipComposeWorker` chama o save do webclipper com
  `draft: true` (scholion-webclipper `5150248`, Decision 11): clipping e nota vão para o vault com
  `draft: true` e `audit_verdict: "red"` no frontmatter, e o Hugo não os publica. O resultado fica em
  `results.webclip_draft` (slug, caminhos, commit) e o aviso no Telegram diz onde o rascunho está. Se o save do
  rascunho falhar, o pipeline estaciona do mesmo jeito e o aviso diz que o rascunho não foi gravado.
- **Retomar recompõe por cima do rascunho** — `Webclip.with_draft_slug/2` põe o `slug` do rascunho no `compose`
  seguinte; o save que vier depois (green/yellow, ou red de novo como rascunho) substitui o arquivo, em vez de
  criar uma segunda nota. Descartar mantém o rascunho no vault.
- `Webclipper.save/2` aceita `draft: true`.

## [0.2.49] — 2026-11-17

### Webclip em fila serial e conferência da URL da resposta

Em 2026-11-16, 31 webclips enviados de uma vez (até 5 compose simultâneos na fila `default`, ao lado de outro
lote batendo direto no webclipper) receberam respostas trocadas: 13 pipelines gravaram ou tentaram gravar a nota de
outra URL, um recebeu um artigo do lote da outra sessão, e vários saves deram timeout com 502 no nginx. A causa da
troca não foi isolada; os dois serviços tratam cada requisição de forma isolada, então ela fica no transporte, sob
carga.

- **Fila `webclip: 1`** — `WebclipComposeWorker` e `WebclipSaveWorker` saem da `default` (limite 5) para uma fila
  própria de limite 1. Qualquer quantidade de webclips enviados vira uma fila em série no webclipper, e a `default`
  deixa de ser disputada com os passos de podcast. `WebclipQuotesWorker` fica na `default` (não chama o webclipper).
- **Conferência da URL** — `Webclip.classify_compose/3` compara o `clipping.url` da resposta com a URL enviada
  (`Webclip.same_url?/2`, ignorando esquema, `www.`, barra final e caixa do host; a query conta). Diferente: nova
  tentativa enquanto houver, e na última o pipeline estaciona com motivo `response_mismatch` sem gravar nada.
  Retomar com `resume_parked` recompõe.
- A mensagem de retry do compose passa a incluir a URL do clipping recebido.

## [0.2.48] — 2026-11-16

### gpt-5.1 na anotação automática e no webclip (perfil `third-party`)

Decidido a partir dos testes de 2026-11-16 (nota do Obsidian "Roteamento de modelos por caso de uso"):

- **Anotação** (`toscanini/annotate`, `podcast/suggest-annotations`, `podcast/annotate`): `gpt-5.1` → `gpt-5.2`. Escolhe
  os trechos como o gpt-5.2 (cobertura dos bookmarks do autor igual, acima do aleatório), cita com a mesma
  fidelidade, custa ~25% menos e escreve descrições mais longas. Os Gemini testados sugerem metade e escolhem pior.
- **Webclip** (`scholion/webclip-summary`): `gpt-5.1` → `gpt-5.4-mini`; no perfil `anthropic`, Sonnet na frente. O
  `scholion-webclipper` deixa de forçar o modelo pelo próprio `.env` e passa a seguir esta tabela.
- **Ghost-audit**: fixtures 8/8 com `gpt-5.2` e `gpt-5.4`; cadeia mantida.
- Semente, testes e o `annotate_model` de reserva do `config.exs` acompanham.

## [0.2.47] — 2026-11-16

### Jobs interrompidos por restart voltam para a fila

Sem o plugin `Lifeline`, um job em andamento quando o serviço parava (restart, crash, BSOD) ficava `executing`
para sempre, e o pipeline dele travava em silêncio. Até aqui a saída era só reiniciar com a fila vazia.

- **`Toscanini.ObanRescue`** — filho da árvore de supervisão entre o `Repo` e o `Oban`. No boot, todo job
  `executing` vira `available` (é órfão por definição: o Toscanini é um nó só) e tem a tentativa devolvida
  (`attempt - 1`), para que vários restarts seguidos não esgotem o `max_attempts` e descartem o episódio. Loga
  cada job resgatado. O trabalho recomeça do zero: o whisper morre junto com o serviço (`KillMode=control-group`).
- O `Lifeline` foi descartado: resgata por idade, e uma transcrição passa de uma hora.
- **`mix test` deixa de usar o banco de produção.** O `config/runtime.exs` roda em todo ambiente e definia o
  `database` do Repo também em teste, por cima do `/tmp/toscanini_test.db` do `config/test.exs`: a suíte sempre
  rodou contra `data/orchestrator.db`. O sandbox desfazia as transações, mas o boot da aplicação não passa por ele,
  e na primeira rodada com o `ObanRescue` o boot de teste marcou como `available` os dois jobs de transcrição que
  estavam rodando em produção (não chegaram a ser pegos de novo; o restart seguinte os resgatou). Agora o Repo só é
  configurado no `runtime.exs` fora de `:test`, e o `ObanRescue` não roda com o Oban em `testing: :manual`.

## [0.2.46] — 2026-11-16

### Roteamento de modelos por caso de uso, com perfis `anthropic` e `third-party`

As cadeias de modelos estavam espalhadas em oito presets da vox-intelligence, no `.env` dela, no `config.exs`
daqui e no `openclaw.json` do Claudinho. Trocar de Anthropic para GPT/DeepSeek (ou voltar, quando há crédito
Anthropic) era editar código em três lugares e reiniciar. Agora a tabela mora aqui, com os dois perfis completos e
um perfil ativo, no mesmo padrão do `queue_schedules.json`.

- **`Toscanini.ModelRouting`** — `data/model_routing.json` (vivo) sobre `priv/model_routing.default.json`
  (semente versionada, vale quando o vivo falta ou está inválido). Cada gravação guarda a versão anterior em
  `data/model_routing_backups/` (últimas 30) e pede refresh à vox-intelligence. `missing_models/1` confere as
  cadeias contra o catálogo do OpenRouter.
- **API** — `GET /model-routing`, `GET /model-routing/resolved`, `PUT /model-routing/profile`
  (`{"profile": "anthropic"}`), `PUT /model-routing/cases/*key` (`{"profile", "chain"}`). Os PUT devolvem
  `warnings` com modelos fora do catálogo.
- **MCP** — `get_model_routing`, `set_model_profile`, `set_model_chain`.
- **`AnnotateWorker`** — lê o caso `toscanini/annotate`; o `annotate_model` do config vira reserva.
- **Troca completa** (Toscanini + vox-intelligence + Claudinho): `C:\scripts\Set-ModelProfile.ps1 anthropic`.
- **`deploy/model-routing/`** — cópias canônicas do `Set-ModelProfile.ps1` (Windows) e do `model-profile.sh`
  (ClaudinhoSandbox), mais o `Install-ModelRouting.ps1`, que instala as duas e confere o SHA-256. As cópias em
  `C:\scripts` e `~/.openclaw/scripts` são só instaladas; editar aqui.

## [0.2.45] — 2026-11-16

### Anotação automática volta ao GPT

Sai o Claude Sonnet 5.5 (BYOK Anthropic no OpenRouter) dos dois passes da anotação automática, por custo.
A cadeia volta à da v0.2.20: `openrouter/openai/gpt-5.2`, fallback `openrouter/openai/gpt-5.1`. DeepSeek e
Gemini Flash continuam de fora, porque perderam cobertura em podcasts discursivos.

- **`config/config.exs`**: `annotate_model` e `annotate_fallback_models`. O override `TOSCANINI_ANNOTATE_MODEL`
  segue valendo.

## [0.2.44] — 2026-11-15

### `podcast_slug` no frontmatter dos episódios (página `/podcasts/` do Vox)

O Vox ganha a página `/podcasts/` (lista de programas e uma página por programa), montada pelo Hugo como
taxonomia. O caminho de cada página vinha do nome bruto do podcast e o build roda no Windows: `Scott & Mark
Learn To...` (ponto final) e um eventual `Nul` (nome reservado) viram pastas inválidas e derrubam o build
inteiro. A correção é na origem: o renderer grava um slug seguro e o Hugo usa esse campo.

- **`Toscanini.PodcastSlug.slug/1`** — `[a-z0-9-]`, sem acento, apóstrofo não separa palavra (`lennys`),
  nunca vazio (`podcast-<hash>`), nunca nome reservado do Windows (sufixo `-podcast`), até 80 caracteres.
  Determinístico: grafias que só diferem em caixa/acento/pontuação caem na mesma página.
- **Renderer** — `podcast_slug:` logo depois de `podcast:`. Derivado de `metadata.podcast` na renderização;
  o JSON não muda.
- Episódios existentes: `.md` regenerados a partir dos JSONs (só a linha nova muda).
- Testes: `podcast_slug_test.exs` (10) + asserts no `vox_pocketcast_json_renderer_test.exs`. Precisa de restart
  do Toscanini para entrar em vigor.

## [0.2.43] — 2026-11-15

### Webclip no Toscanini (`POST /publish/webclip`) e fila de pipelines estacionados (`/parked`)

O fluxo de webclip sai das skills e passa a ser um pipeline do Toscanini. Qualquer agente (o Claudinho ou
quem o substituir) só faz um POST com a URL; retentativa, fallback de navegador, citações e aviso são passos
do pipeline. O webclipper continua sendo só o serviço de fetch, compose e save.

- **`POST /api/orchestrator/publish/webclip`** — `{url, quotes?, comment?}`. Cria um pipeline `scholion_webclip`:
  `webclip_compose → webclip_save → webclip_quotes → notify`. A mesma URL já feita, em andamento ou estacionada
  devolve o job existente (`duplicate: true`).
- **Estado `parked`** (`Pipeline.park/3`) — o que o servidor sozinho não resolve não falha: espera o Claude Code
  da máquina do autor. Motivos: `browser` (`blocked_domain`, `consent_wall_unresolved`, `thin_content`, ou
  `fetch_*` em todas as tentativas), `audit_red`, `audit_unavailable`, `slug_conflict`. Aviso no Telegram
  ao estacionar. As decisões ficam em `Toscanini.Webclip` (puro, testado).
- **Fila** — `GET /parked`, `POST /parked/:id/resume` (webclip: `text`/`title` capturados no Chrome e/ou
  `related_notes`; volta ao compose em modo texto) e `POST /parked/:id/dismiss` (falha como `manual`, fora dos
  contadores). `Dispatcher.rerun/1` reenfileira o passo atual. `Status` ganha `totals.parked`.
- **Save em modo `commit`** — o webclipper grava clipping + nota no próprio clone, um commit, e faz push.
  Autentica como o principal `toscanini` (role `write`, nunca força red): `WEBCLIPPER_API_KEY` no unit.
- **Citações** — `webclip_quotes` abre um pipeline `scholion_quote` por frase, com a página como fonte.
  A criação do pipeline de citação foi extraída para `Toscanini.Scholion.QuoteJob` (usada também por
  `/publish/scholion`).
- **MCP** — `publish_webclip`, `list_parked`, `resume_parked`, `dismiss_parked`.
- Testes: 154 (`test/toscanini` + `webclip_controllers_test.exs`). O `ConnCase` continua quebrado
  (`verified_routes/0` não existe), então o teste de controller monta o `ConnTest` à mão.

## [0.2.42] — 2026-11-10

### Ingestão privada: `--tag` para agrupar episódios + skill `/vox-ingest-private`

O resumo do LLM sobrescreve `tags` no sidecar, então a tag pedida na ingestão viaja em `metadata.user_tags` e o
passo `enrich_tags` a acrescenta às `tags` do episódio (em slug, sem repetir). No Vox, o Hugo já tem a taxonomia
`tags`: os episódios aparecem juntos em `/tags/<tag>/`.

- **`scripts/ingest-private.ts`** — `--tag grupo` (repete ou usa vírgula); `parseTags` em `ingest-private-lib.ts`.
- **`EnrichTagsWorker`** — `user_tags/1` e `new_tags/3` (públicas, testadas). Vale só para episódios novos: um slug já enviado
  devolve `duplicate` e não recebe tag. Precisa de restart do Toscanini para entrar em vigor.
- **Skill `/vox-ingest-private`** (em `~/.claude/skills`) — recebe arquivo ou pasta, pergunta o curso, ensaia com `--dry-run`,
  envia e relata. Testes: 16 em `scripts/` e 130 em `test/toscanini`.

## [0.2.41] — 2026-11-10

### Whisper: VRAM mínima para a GPU cai de 5200 para 4600 MiB

Com o Windows (dwm do RDP + sessão Console) ocupando ~1,2 GB da RTX 3050, a placa nunca chegava a 5200 MiB
livres e tudo ia para a CPU. O piso passa a 4600 MiB (`WHISPER_MIN_FREE_VRAM_MB`, padrão em `priv/whisper_worker.py`).
Se o large-v3 cair por falta de memória, o cooldown de 15 min (exit 134) continua protegendo.

## [0.2.40] — 2026-11-09

### Telegram: o aviso de episódio privado leva o link do site privado

O aviso do pipeline para conteúdo privado saía sem URL. O Telegram é particular, então agora leva o
link `https://vox.thluiz.com/privado/<guid>/<ano>/<mês>/W<semana>/<slug>/`, tanto na mensagem padrão
quanto na lista de anotações novas.

- **`PrivateSite`** (novo) — monta a URL; o guid vem de `TOSCANINI_VOX_PRIVATE_GUID` (no unit do systemd,
  como as outras chaves; nunca no código nem no git). Sem a variável, não há link e a mensagem sai igual
- **`NotifyWorker`** — `episode_url/3`; `build_message` recebe a URL pronta. Para episódio público a
  mensagem não muda
- A página só existe depois do próximo publish do Vox privado (a tarefa roda a cada 15 min); o publish
  também manda ao Telegram um aviso com os links dos episódios novos, já no ar
- Testes de `PrivateSite`; a notificação foi exercitada de ponta a ponta com um GossipGate falso (6 verificações)

## [0.2.39] — 2026-11-09

### ingest-private: slug sem repetir o curso, título legível e `--title`

O primeiro arquivo real ("aula-extra-henry-kissinger-…" no curso "Petit Cursos: Henry Kissinger") gerava o
slug `petit-cursos-henry-kissinger-aula-extra-henry-kissinger-…`, repetindo o nome.

- **Slug** — as palavras do curso que já aparecem no nome do arquivo saem do prefixo
  (`petit-cursos-aula-extra-henry-kissinger-…`); continua estável entre execuções
- **Título** — nome de arquivo em kebab-case vira texto com espaços e inicial maiúscula (sem acentos:
  eles não existem no nome do arquivo)
- **`--title "Título"`** (um arquivo por vez) define o título, com acentos, quando o nome do arquivo não basta

## [0.2.38] — 2026-11-09

### `scripts/ingest-private.ts`: MP3 de cursos para o pipeline privado, em lote

Os MP3 de cursos e aulas chegam aos poucos; o script pode ser rodado de novo sobre a mesma
pasta e só o que é novo entra.

- `bun scripts/ingest-private.ts --course "Nome do Curso" [--author N] [--dry-run] <arquivo-ou-pasta>...`
- Para cada MP3: copia para `/home/hermes/collected` com o slug `<curso>-<arquivo>` (pula a cópia
  se o tamanho já bate), mede a duração com o `ffprobe` do HermesTools e chama
  `POST /ingest/local` com `private: true`. O título sai do nome do arquivo sem extensão nem
  prefixo de ordem; o curso vira o campo "podcast"; a data é a do arquivo
- Funções puras em `ingest-private-lib.ts`, testadas com `bun test scripts/`; a cópia binária
  pelo stdin, o tamanho e a duração foram conferidos à parte no HermesTools (md5 idêntico)
- Só funciona de verdade a partir da v0.2.37 em produção (antes o `/ingest/local` ignora `private`)

## [0.2.37] — 2026-11-09

### Modo privado completo no Toscanini; remove os passos de verificação de URL e Facebook

Fecha as pontas soltas do pipeline privado (v0.2.34) para as ferramentas que já usamos
no Vox continuarem valendo sobre o material privado: o conteúdo usa o mesmo formato
do Vox (`YYYY/MM/Wnn/<slug>.md` + `.json`), só com outra raiz.

- **`ContentRepos`** (novo) — as duas raízes (`TOSCANINI_VOX_CONTENT_DIR` e, se definida,
  `TOSCANINI_VOX_PRIVATE_DIR`) e a localização de um episódio por path ou slug; aceita o
  prefixo `privado/<token>/` do site privado e barra final
- **`POST /annotate`** — procura o episódio nos dois repositórios; o achado no privado
  gera um pipeline privado, que escreve de volta no repositório privado. Antes só olhava o
  público e não acharia nada privado
- **`POST /ingest/local`** — aceita `private: true`: marca o pipeline e o sidecar
  (`metadata.private`) e ignora reenvio do mesmo slug (os arquivos chegam aos poucos)
- **`POST /batch`** e as tools `submit_job`/`submit_batch` do MCP — aceitam `private`
- **`RetentionSweepWorker`** — nunca apaga o áudio local de conteúdo privado: o MP3 é a
  fonte para cortar trechos e mandar ao Mesa
- **Removidos** `VerifyUrlWorker`, `FacebookCacheRefreshWorker` e o client do Facebook,
  só alcançáveis pelo passo `vox_publish` que saiu na v0.2.35, junto com as entradas do
  dispatcher, `FACEBOOK_APP_TOKEN`/`FACEBOOK_REFRESH_DELAY` (config, unit e README)
- **Testes** — `ContentRepos`, `RetentionSweepWorker.private?/1`; os controllers foram
  exercitados de ponta a ponta com banco temporário (18 verificações)

## [0.2.36] — 2026-11-09

### Whisper só pega a GPU com 5,2 GB de VRAM livres; modelo de janelas 10h–21h

O large-v3 em float16 ocupa quase toda a VRAM da RTX 3050 (~5 de 6 GB): qualquer
outro uso da GPU o derruba com `CUDA out of memory`. Começar assim só gasta a
tentativa, então a checagem passa a ser antes de começar.

- **`whisper_worker.py`** — com o lock da GPU em mãos, `select_model/0` espera até
  20 s a VRAM do job anterior ser liberada (`wait_for_vram`) e exige
  `WHISPER_MIN_FREE_VRAM_MB` (padrão 5200 MiB) livres; senão solta o lock e segue
  para a CPU. `nvidia-smi` falhando conta como 0 (CPU, nunca GPU às cegas).
  `WHISPER_VRAM_WAIT_SECS` ajusta a folga
- **`priv/queue_schedules.json`** e README — modelo alinhado com produção: sem GPU
  das 10h às 21h em dia útil, GPU livre no fim de semana. Docstring do worker
  corrigido (descrevia uma seleção por VRAM que não existia)

## [0.2.35] — 2026-11-09

### Remove o passo `vox_publish` (código morto do tempo do Quartz + Azure)

O Vox hoje é Hugo + S3 + CloudFront, publicado pelo `vox-publish-windows.ps1` (a
cada hora, no Windows, a partir do que foi empurrado para o `vox-content`). O
Toscanini não publica o site: o fluxo termina em `git_commit → s3_archive → notify`.
O `VoxPublishWorker` ainda chamava o `vox-publish` antigo do HermesTools
(Quartz + Azure Static Web Apps), que já foi removido do host, e nenhum passo o
enfileirava desde que o `GitCommitWorker` passou a avançar para o `s3_archive`.

- **`VoxPublishWorker`** removido, junto com a entrada `"vox_publish"` do dispatcher
  e a fila `vox_publish` do Oban (`config.exs`); `Oban.Config.new/1` validado
- **`deploy/toscanini.service`** — sai `TOSCANINI_VOX_PUBLISH_BIN`
- **README** — diagrama corrigido (inclui `AnnotateWorker` e `S3ArchiveWorker`, sem
  `VoxPublish`/`VerifyUrl`/`FacebookCacheRefresh`), explica que o site é publicado
  fora do Toscanini; saem a variável e a fila removidas
- Não tocados: `VerifyUrlWorker` e `FacebookCacheRefreshWorker` seguem no código,
  mas só eram alcançáveis pelo passo removido (hoje sem uso)

## [0.2.34] — 2026-11-09

### Base do pipeline privado: conteúdo no repo git privado, sem URL pública

Trabalho que estava só no working tree, agora commitado. Um pipeline com
`params.private == true` escreve e commita no repo apontado por
`TOSCANINI_VOX_PRIVATE_DIR` em vez do `vox-content` público, e a notificação não
leva link público (o repo privado não é servido). **Ainda não há como criar um
pipeline privado**: nenhum endpoint nem tool MCP preenche `private`, então todo
pipeline continua público e o comportamento atual não muda.

- **`Pipeline`** — `private?/1` e `content_dir/1`; um pipeline privado sem
  `TOSCANINI_VOX_PRIVATE_DIR` falha (`fetch_env!`), nunca cai no repo público
- **`WriteFilesWorker`** e **`GitCommitWorker`** — usam `Pipeline.content_dir/1`
- **`NotifyWorker`** — pipeline privado manda só o path, sem URL, nas mensagens
  padrão e de anotação. `build_message` ganhou o argumento `private?`: o commit
  parcial chamava `build_message/8` com a função ainda de 7 argumentos e o módulo
  não compilava
- **Testes** — `pipeline_private_test.exs` cobre `private?/1`, `content_dir/1` e a
  falha sem a variável de ambiente

## [0.2.33] — 2026-11-08

### Whisper nunca roda sem slot: no máximo 2 transcrições em CPU ao mesmo tempo

Com o cooldown da GPU aberto (ou o lock da GPU ocupado), o terceiro job da janela
(`limit: 3`) ia para a CPU, esperava 120 s por um slot e então seguia "anyway" sem
lock. Resultado: 3 transcrições em CPU disputando os mesmos núcleos, todas com ETA
de 5 a 11 h para episódios de ~1 h.

- **`whisper_worker.py`** — `select_model/0` agora bloqueia até conseguir o lock da
  GPU ou um slot de CPU (`try_acquire_cpu_slot`, uma passada, sem timeout). A cada
  5 s reavalia janela, cooldown e lock da GPU, então um job que esperava vaga vai
  para a GPU assim que ela abre. O job de espera ocupa uma vaga do Oban sem
  consumir CPU. `acquire_gpu_lock(quiet=True)` evita logar "held by pid" a cada
  passada

## [0.2.32] — 2026-11-08

### Cooldown de 15 min da GPU quando o whisper aborta; janelas por dia da semana

Na janela da GPU (00h–09h e 20h–24h) quase toda transcrição morria com
`CUDA failed with error out of memory`: 146 abortos em 166 inícios na GPU entre
07/11 e 08/11, 46 jobs descartados (exit 134) e 46 pipelines órfãos em
`running / transcribe`, sem nenhum alerta de falha no status. O aborto é do
CTranslate2 (`std::terminate`): derruba o processo inteiro, então o fallback para
CPU que existia em `whisper_worker.py` nunca roda, e o Oban retentava na GPU até
descartar. A RTX 3050 de 6 GB não comporta o `large-v3` em float16; a correção de
fundo é hardware, então aqui só se limita o estrago.

- **`gpu_cooldown.ex`** (novo) — `data/gpu_cooldown.json` com `until`; cooldown
  fixo de 15 min, reiniciado a cada novo aborto
- **`TranscribeWorker`** — exit 134 com a GPU em jogo (janela com `gpu: true` e sem
  cooldown aberto) abre o cooldown e devolve o job à fila com `{:snooze, 10}`, sem
  gastar tentativa; 134 fora da GPU segue como erro comum. `classify_exit/2` isola a regra
- **`whisper_worker.py`** — `select_model/0` pula a GPU enquanto o cooldown estiver
  aberto e manda o job para a CPU; passados os 15 min, o próximo job tenta a GPU de novo
- **`scheduler.ex`** (novo) — as janelas de `queue_schedules.json` ganham `days`
  opcional (`mon`..`sun`); sem `days` vale todo dia, a primeira janela que casa
  com hora e dia ganha. Worker, controller e `whisper_worker.py` usam a mesma regra
- **`SchedulerController`** — valida `days`; o limite aplicado no `PUT` agora usa
  a hora local, como o worker (antes usava UTC)
- **`priv/queue_schedules.json`** e README — janelas novas: sem GPU só de 12h às
  20h em dia útil, GPU livre o dia todo no fim de semana
- **`mcp/mcp.ts`** — `set_scheduler_config` documenta `days`

## [0.2.31] — 2026-11-04

### Frontmatter do Vox: aspas em valores que terminam em `:` ou começam com `@`

Dois episódios commitados em 2026-11-03 tinham frontmatter YAML inválido (título
terminando em `:` e `podcast: @Canal`). O `hugo` falhava no build e o publish do
Vox ficou parado desde as 18:51, sem episódio novo no ar.

- **`vox_pocketcast_json_renderer.ex`** — `needs_quoting?/1` passa a citar valores
  que terminam em `:` e os que começam com `@`, `` ` `` ou `%`
- Os dois `.md` afetados foram corrigidos direto no `vox-content`

## [0.2.30] — 2026-11-01

### Chamadas à vox-intelligence agrupadas por pipeline no Langfuse

A vox-intelligence 1.4.0 repassa o header `x-session-id` ao OpenRouter como
`session_id`, e o Broadcast do OpenRouter manda isso ao Langfuse. Com o id do
pipeline como sessão, dá para ver quanto custou cada episódio ou citação.

- **`clients/vox_intelligence.ex`** — todas as funções aceitam `session_id:` em
  `opts` e mandam o header; `pipeline_session/1` monta o valor
  (`toscanini:pipeline:<id>`). `process_podcast`, `synthesize_quote` e
  `ghost_audit` ganharam `opts \\ []`, então as chamadas antigas seguem valendo
- **`AnnotateWorker`**, **`SummarizeWorker`** e **`ScholionSynthesizeWorker`** passam
  o id do pipeline

## [0.2.29] — 2026-11-01

### Anotação automática passa a usar o Claude Sonnet 5.5

A conta do OpenRouter ganhou uma chave Anthropic (BYOK), então os modelos
`anthropic/*` saem pela conta Anthropic sem trocar a key do Toscanini.

- **`config/config.exs`** — `annotate_model` vira `openrouter/anthropic/claude-sonnet-5.5`;
  `gpt-5.2` e `gpt-5.1`, que atendiam antes, ficam como `annotate_fallback_models`
  nessa ordem.

## [0.2.28] — 2026-10-31

### Whisper refaz a transcrição sem contexto quando sai em loop

Reprocessados com a 0.2.26, três episódios voltaram em loop mesmo com idioma
certo (prob=1.00): os dois do "Le principe de l'inquiétude" (áudio em francês) e
o RapaduraCast 919. Não é áudio nem decode (PyAV e ffmpeg entregam o mesmo sinal):
a 1ª janela de 30s pega a vinheta ("RAPADURACAST, O PODCAST DO PORTAL…") ou
alucina sobre a música de abertura ("Sous-titres par Jérémy Diaz"), e com
`condition_on_previous_text=True` (default) esse texto vira o prompt da janela
seguinte até o fim. Testado nos 5 primeiros minutos: default 10 segmentos iguais;
sem o condicionamento, 121 e 60 segmentos distintos, loop quebrado já aos 30s.

- **`priv/whisper_worker.py`** — transcreve como antes; se o resultado está em loop
  (mesmo critério do `TranscriptCheck`: uma linha ≥ 50% das linhas), refaz com
  `condition_on_previous_text=False`. Só os casos quebrados pagam a segunda
  passada; o guard do `TranscribeWorker` segue como última barreira.

## [0.2.27] — 2026-10-31

Alterações que estavam rodando em produção direto no clone de serviço
(`/home/hermes/services/toscanini`) sem nunca terem sido commitadas, feitas em
2026-08-19 e 2026-09-20. Entram aqui como estavam no serviço, só com os acentos
dos comentários restaurados (o `annotate_controller.ex` tinha sido gravado com
`??` no lugar dos caracteres não-ASCII).

### YouTube: player client `web_embedded` (2026-08-19)

- **`lib/toscanini/collectors/youtube.ex`** — metadata e download passam
  `--extractor-args youtube:player_client=web_embedded,android_vr`. O default
  implícito (`android_vr`) levava 403 intermitente nas URLs de mídia.

### Collect: falha genérica só é definitiva na última tentativa (2026-08-19)

- **`lib/toscanini/workers/collect_worker.ex`** — `{:error, _}` genérico (ex.: 403
  do YouTube) fica em `retrying` nas tentativas intermediárias do Oban e só chama
  `Pipeline.fail` (e notifica) na última.
- **`lib/toscanini/pipeline.ex`** — `save_result` limpa `error`: um passo que
  passou invalida a falha anterior, senão o pipeline terminava `done` com `error`.

### Notificação lista as anotações novas (2026-09-20)

- **`lib/toscanini/workers/annotate_worker.ex`** — `merge_annotations` devolve
  também as anotações efetivamente novas (pós-dedup); o resultado do passo ganha
  `"new"`, com o `tier` da sugestão anexado. O JSON publicado não muda de schema.
- **`lib/toscanini/workers/notify_worker.ex`** — com anotações novas, a notificação
  vira a lista delas (ícone por tier, timestamp, título, descrição curta), dividida
  em quantas mensagens o limite do Telegram exigir, com a URL só na última.

### `POST /annotate`: re-anotar episódio publicado (2026-09-20)

- **`lib/toscanini_web/controllers/annotate_controller.ex`** (novo) — recebe
  `path` (relativo ao vox-content, ou só o slug) e cria um pipeline que começa em
  `summarize`, de modo que o próximo passo é o `AnnotateWorker`; segue o fluxo
  normal até `notify`. Sem re-coletar/transcrever/resumir.
- **`lib/toscanini_web/router.ex`** — rota.

### Outros

- **`.gitignore`** — `data/feeds_config.json` (config de runtime, escrita pela API).

## [0.2.26] — 2026-10-31

### Guard contra transcrição degenerada

Varredura do vox-content achou 7 episódios publicados com transcrição lixo
(passavam no mínimo de 50 palavras): loops de uma frase a cada 30s
("RAPADURACAST, O PODCAST DO PORTAL…", "Sous-titrage Société Radio-Canada"), um
loop parcial de "." e um truncado em 5min de 42min.

- **`lib/toscanini/transcript_check.ex`** (novo) — `check/2`: rejeita se uma
  linha é ≥ 50% das linhas (loop) ou se o último timestamp cobre < 50% da duração
  (truncada; só com duração ≥ 300s). Limiares sem falso positivo nas 5379
  transcrições do acervo.
- **`lib/toscanini/workers/transcribe_worker.ex`** — reprovada no check: falha o
  pipeline, notifica no GossipGate com o motivo e retorna `{:cancel, _}` (sem
  retry: o Whisper repetiria o resultado). O JSON não recebe o transcript.
- **`test/toscanini/transcript_check_test.exs`** (novo).

### Detecção de idioma do Whisper não força palpite de baixa confiança

O `whisper_worker.py` amostrava 30s a partir de 300s fixos para pular a intro.
Num vídeo curto isso caía no fim: em "Living In Barcelona SUCKS..." (376s, inglês)
a amostra em 300s era o end screen, o Whisper chutou `ru` com prob=0.15 e o worker
forçou `language="ru"` na transcrição inteira, saindo só alucinação ("Добро
пожаловать на наш канал!" a cada 30s), que passou raspando no mínimo de 50 palavras.

- **`priv/whisper_worker.py`** — `sample_offsets/1`: o primeiro offset continua
  `max(300s, 10%)`, mas limitado a 40% da duração; amostras extras em 20% e 60%.
  `detect_language` só fixa o idioma com prob ≥ 0.5 (tenta as amostras seguintes
  enquanto estiver abaixo); sem amostra confiável, devolve `None` e o faster-whisper
  detecta sozinho. `ffmpeg` da amostra ganha `-nostdin`.

## [0.2.25] — 2026-10-13

### `metadata.source_url` do PocketCasts vira link que abre

O collector gravava em `metadata.source_url` a URL de entrada do pipeline
(`pocketcasts.com/podcast/<p>/episode/<e>`, ou a da API `podcast-api.../full/...`),
que não abre no site: a página canônica exige os slugs do podcast e do episódio,
e o slug do episódio muda quando o título muda. O rodapé do Vox imprime
`source_url` como está, então o link "PocketCasts —" de ~2200 episódios dava erro.

- **`lib/toscanini/collectors/pocketcasts.ex`** — `share_url/1` monta
  `https://pca.st/episode/<episode_uuid>` (share link oficial, redireciona para a
  página canônica atual); `build_meta` grava isso em `source_url` quando a API
  devolve o `uuid` do episódio. `episode_url/2` continua sendo o formato de
  entrada do pipeline (feeds), não o link público.
- **vox-content** — backfill dos 2179 JSONs com URL quebrada (commit `368a1735`).
  URLs canônicas com slug e as do YouTube ficaram como estavam.

## [0.2.24] — 2026-10-05

### Grafia canônica de participantes no `enrich_tags`

O summarize transcreve nomes de ouvido, então a mesma pessoa chegava ao Vox com
grafias diferentes ("Thomas Trauman" / "Thomas Traumann", 17 variantes de
"Jonathan Cutrell") — e cada grafia virava uma tag/página própria. A tabela
revisada à mão vive no vox-content (`_meta/participants-aliases.csv`, colunas
`variant,canonical`, excluída do build do Hugo) e o `EnrichTagsWorker` aplica
antes de derivar as tags de participante. Cobre o pipeline normal e o
`POST /publish/podcast` (que começa em `enrich_tags`).

- **`lib/toscanini/participant_aliases.ex`** (novo) — `load/1` (arquivo ausente
  → no-op), `normalize/2` (troca `participants` e o slug correspondente em
  `tags`, sem duplicar; retorna a lista de trocas) e `slug/1` (regra das tags,
  movida do worker).
- **`lib/toscanini/workers/enrich_tags_worker.ex`** — normaliza antes de gerar as
  tags; `save_result` ganha `"renamed"`. Tabela relida a cada episódio: edição no
  vox-content vale sem restart, a partir do pull feito no `git_commit` seguinte.
- **`test/toscanini/participant_aliases_test.exs`** (novo).

## [0.2.23] — 2026-08-20

### Notificações vão para o chat próprio do Toscanini (GossipGate `target`)

O GossipGate ganhou um registry de destinos nomeados (`destinations.json` →
`chat_id`). O Toscanini passa a mandar tudo com `target: "toscanini"`, tirando o
ruído de processamento do chat geral. Roteamento fica no cliente HTTP, não
espalhado pelos workers — todos os pontos de notificação herdam de graça:
`NotifyWorker` (episódio + citação Scholion), `BatchAdvanceWorker` (resumo de
batch), `RetentionSweepWorker` (varredura) e `ObanNotifier` (falha de pipeline).

- **`lib/toscanini/clients/gossip_gate.ex`** — `send/3` inclui `"target"` no
  corpo do POST; terceiro argumento opcional permite override por chamada, `nil`
  cai no destino default. HTTP não-200 agora reporta o target no erro.
- **`config/runtime.exs`** — `:gossipgate_target`, de `GOSSIPGATE_TARGET`,
  default `"toscanini"`. Para voltar ao chat geral: `GOSSIPGATE_TARGET=default`.

## [0.2.22] — 2026-07-17

### Assinatura infere a janela quente (check_days) da cadência do feed

Ao assinar um podcast **sem** `check_days` explícito, o Toscanini passa a derivar
os dias da janela quente da própria cadência de publicação — em vez de deixar o
hot sempre ligado (poll horário todo dia). O `prime_watermark` já busca o feed
inteiro para gravar o watermark, então o histograma sai de graça no mesmo fetch.
Objetivo: clientes burros (ex.: script do ClaudinhoSandbox) mandam só a URL e o
agendamento certo é responsabilidade do servidor.

- **`lib/toscanini/feeds.ex`** — `subscribe/1` marca `infer_schedule?` quando
  `check_days` não vem nos attrs; `prime_watermark/2` chama `infer_check_days/2`
  e grava os dias no mesmo update do watermark. `check_days` explícito (mesmo `[]`)
  é respeitado — `[]` continua significando hot sempre ligado.
- **`infer_check_days/2`** (função pura) — histograma de dia-da-semana (UTC) dos
  até 12 episódios mais recentes; menor conjunto de dias no topo cobrindo ≥80% da
  amostra (máx. 3), + vizinho ±1 dia com ≥25% (drift de meia-noite/fuso). Amostra
  < 4 ou espalhada por ≥5 dias → `[]`. Episódios já vêm em UTC, mesmo referencial
  de `hot?/2`/`due?/2`.
- **`test/toscanini/feeds_test.exs`** — cobre semanal, amostra pequena, diário,
  drift seg/ter e `published` inválido.

## [0.2.21] — 2026-07-17

### Feed com 1 episódio novo → job avulso (sem batch)

Corta a notificação redundante de "✅ Batch concluído — 1/1 episódios publicados"
que vinha empilhada sobre a notificação do próprio episódio. Em regime estável
cada feed solta 1 episódio por check, então quase todo batch automático era de
tamanho 1 e o resumo não agregava nada além do que a notificação do episódio já
dizia. Mudança escopada só no produtor de feeds — a máquina de batch (partilhada
com a submissão manual do `BatchController`) fica intacta.

- **`lib/toscanini/feeds.ex`** — `check/1`: 1 episódio novo → `submit_single/3`
  (cria o `Pipeline` "queued" e chama `Dispatcher.advance`, mesmo caminho do
  `JobController`); ≥2 episódios (backlog inicial / catch-up da rede de segurança)
  → `Batches.start_batch` como antes, que serializa o processamento e manda o
  resumo agregado. Falhas de episódio único continuam notificadas pelo
  `ObanNotifier` global (independente de batch).

## [0.2.20] — 2026-07-15

### Anotação automática passa a usar GPT (suggest + annotate)

Os dois passes da anotação automática deixam de usar os modelos baratos default
do preset (Gemini Flash no suggest, DeepSeek no annotate) e passam a usar **GPT**
(`openrouter/openai/gpt-5.2`, fallback `gpt-5.1`). Motivo: cobertura/qualidade —
o modelo barato perdia beats conceituais em podcasts discursivos (PT).

- **`config/config.exs`** — `annotate_model` + `annotate_fallback_models` (default GPT).
- **`config/runtime.exs`** — override sem redeploy via `TOSCANINI_ANNOTATE_MODEL`.
- **`lib/toscanini/clients/vox_intelligence.ex`** — `suggest_annotations/2` e `annotate/3`
  aceitam `model`/`fallback_models` (injetados no corpo do preset).
- **`lib/toscanini/workers/annotate_worker.ex`** — passa o modelo configurado nos dois passes.

### Retenção vira filesystem-driven (passa a cobrir o backlog)

Correção da retenção introduzida em 0.2.18: a versão original consultava o banco
de pipelines (`results.s3_archive.done`), mas os ~157 GB do backlog foram
arquivados pelo script standalone — **sem** esse registro, e com `archived_at` =
data do arquivamento — então **nunca seriam limpos**. Reescrita como
**filesystem-driven**: varre `collected/*.json`, usa o `mtime` do áudio (data do
download) como idade e apaga só com `head-object` confirmando o objeto no S3.
Cobre uniformemente backlog **e** going-forward, sem depender do banco. Travas
inalteradas (`enabled?` + `backlog_done` + `dry_run`).

- **`lib/toscanini/workers/retention_sweep_worker.ex`** — lógica filesystem-driven
  (`mtime` + `object_exists?`), sem `Repo`/`Pipeline`.

## [0.2.19] — 2026-07-14

### Anotação automática por feed — passo `annotate` no pipeline

Alguns programas passam a ser anotados sozinhos assim que um episódio novo é
publicado, espelhando o fluxo das skills `suggest-annotations` → `podcast-annotate`
(sem os gates humanos — roda direto no pipeline):

1. `suggest_annotations` (modelo barato) → 8–20 sugestões com timestamps;
2. `annotate` desses timestamps → anotações ricas (título + descrição);
3. mescla no campo **`annotations`** do JSON (dedup por janela de 30s vs. as
   existentes, ordena por `ts`) — **nunca toca no `timeline`**.

**Opt-in por feed** via a flag `auto_annotate` (default `false`): só os feeds
marcados anotam; entrada manual (`/jobs`) não é afetada. A flag é propagada do
feed para os `params` do pipeline via `extra_params` do batch (herdada por todos
os itens). O passo é **não-bloqueante**: falha na vox-intelligence é logada e o
pipeline segue publicando sem anotações (podem ser adicionadas depois pelas skills).

- **`priv/repo/migrations/20260714120000_add_auto_annotate_to_feed_subscriptions.exs`**
  — nova coluna `auto_annotate boolean default false`.
- **`lib/toscanini/feed_subscription.ex`** — campo + castable.
- **`lib/toscanini/feeds.ex`** — allowlist do update + `check/1` passa a flag ao batch.
- **`lib/toscanini/clients/vox_intelligence.ex`** — `suggest_annotations/1` e `annotate/2`
  (presets `podcast/suggest-annotations` e `podcast/annotate`).
- **`lib/toscanini/workers/annotate_worker.ex`** — novo worker (no-op se a flag for falsa).
- **`lib/toscanini/pipeline/dispatcher.ex`** — passo `annotate` entre `summarize` e `enrich_tags`.
- **`lib/toscanini_web/controllers/feed_controller.ex`** — `auto_annotate` no `render_sub`.
- **`mcp/mcp.ts`** — `subscribe_feed` aceita `auto_annotate`; nova tool `update_feed`
  (toggla a flag / edita um feed existente).

## [0.2.18] — 2026-07-14

### Retenção: varredura diária que apaga áudio local já arquivado no cold

Fecha o ciclo do arquivamento: um cron diário (04:30 UTC) apaga o áudio LOCAL de
episódios arquivados no cold storage há mais de `retention_days` (default 30),
liberando o disco do `collected`. Conservador e auto-gated:

1. No-op se `Archive.enabled?/0` for `false`.
2. No-op se `TOSCANINI_ARCHIVE_BACKLOG_DONE != true` — trava: nunca limpa antes de
   todo o histórico estar confirmado no cold.
3. `dry_run` (default `true`) só loga os candidatos, não apaga.
4. **Nunca apaga sem confirmar o objeto no S3** (`head-object`).

Apaga só o áudio (`collect.mp3`/`collect.audio`); a transcrição do youtube e o mp3
do podcast já estão no cold. Loga total liberado e notifica no GossipGate.

- **`lib/toscanini/workers/retention_sweep_worker.ex`** — novo worker.
- **`config/config.exs`** — entrada de crontab `{"30 4 * * *", RetentionSweepWorker}`.

## [0.2.17] — 2026-07-14

### Arquivamento em cold storage (S3) — passo `s3_archive` no pipeline

Novo passo entre `git_commit` e `notify` que arquiva o áudio/transcrição em cold
storage assim que o episódio é publicado, pra depois liberar o disco do
`collected` (que já passava de 160 GB). **Não apaga nada** — só arquiva; a limpeza
local (retenção) vem em passo futuro, e nunca sem o objeto confirmado no S3.

- **Podcast** (`metadata.source != "youtube"`): sobe o MP3 → `podcasts/<slug>.mp3`
  (storage class Deep Archive por padrão).
- **YouTube**: sobe só a transcrição → `youtube/<slug>.txt` (STANDARD); o áudio é
  re-baixável do YouTube.

Desligado por padrão (feature-flag): sem `TOSCANINI_ARCHIVE_ENABLED=true` + bucket,
o passo é no-op (pass-through) — deploy inerte, zero impacto nos episódios atuais.

- **`lib/toscanini/archive.ex`** — novo: cliente fino do `aws` CLI (`put/3`,
  `object_exists?/1`, `enabled?/0`), config runtime sob `:archive`.
- **`lib/toscanini/workers/s3_archive_worker.ex`** — novo: passo `s3_archive`,
  detecta tipo por `metadata.source`, idempotente (`head-object`), no-op se off.
- **`lib/toscanini/pipeline/dispatcher.ex`** — aresta `git_commit → s3_archive →
  notify`.
- **`config/runtime.exs`** — bloco `:archive` (envs `TOSCANINI_ARCHIVE_*`, todos
  com default seguro; flag OFF).

## [0.2.16] — 2026-07-14

### Folga configurável na janela quente (corrige check a cada 2h)

Bug: como cada check gravava `last_checked_at` alguns segundos após a hora cheia
(ex.: 16:00:04), o sweep horário seguinte via `DateTime.diff(:minute)` = 59min <
60 e **pulava** — resultando em check a cada 2h em vez de 1h nos dias quentes.

Fix: o limiar da janela quente ganha uma folga configurável — devido quando
`elapsed >= hot_interval_min - hot_grace_min`. `hot_grace_min` default 10,
editável em runtime pelo mesmo `/feeds/config` (e `data/feeds_config.json`).

- **`lib/toscanini/feeds_config.ex`** — novo campo `hot_grace_min` (default 10,
  valida 0–59); `validate` generalizado p/ múltiplas chaves.
- **`lib/toscanini/feeds.ex`** — `due?/2` subtrai a folga no limiar da janela quente.

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
