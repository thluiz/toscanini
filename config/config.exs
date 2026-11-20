import Config

config :toscanini,
  ecto_repos: [Toscanini.Repo],
  generators: [timestamp_type: :utc_datetime]

# Modelo dos dois passes da anotação automática (suggest + annotate). Quem manda é o
# roteamento (Toscanini.ModelRouting, caso `toscanini/annotate`); isto só vale se ele
# não tiver cadeia para o caso. DeepSeek e Gemini Flash já perderam cobertura aqui
# (v0.2.20), não usar. TOSCANINI_ANNOTATE_MODEL (config/runtime.exs) mexe só neste
# valor de reserva.
config :toscanini,
  annotate_model: "openrouter/openai/gpt-5.1",
  annotate_fallback_models: ["openrouter/openai/gpt-5.2"]

config :toscanini, ToscaniniWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ToscaniniWeb.ErrorJSON],
    layout: false
  ],
  server: true

config :toscanini, Oban,
  engine: Oban.Engines.Lite,
  repo: Toscanini.Repo,
  # webclip: 1 — compose/save hit the webclipper one at a time. Concurrent
  # compose calls got each other's responses on 2026-11-16 (see CHANGELOG 0.2.49).
  queues: [collectors: 3, digest: 1, default: 5, git_commit: 1, transcribe: 2, feeds: 1, webclip: 1],
  plugins: [
    # Varre assinaturas de feed de hora em hora (no minuto 0). O worker gateia
    # cada assinatura por janela quente/idle, então isto é barato (conditional GET).
    # Retenção: 1×/dia (04:30 UTC) apaga áudio local já arquivado no cold há >N dias.
    # O worker é auto-gated (enabled? + backlog_done + dry_run), então é no-op por padrão.
    # TranscribeFeed: rede de segurança do portão da fila de transcrição (1×/min).
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Toscanini.Workers.FeedSweepWorker},
       {"30 4 * * *", Toscanini.Workers.RetentionSweepWorker},
       {"* * * * *", Toscanini.Workers.TranscribeFeedWorker}
     ]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
