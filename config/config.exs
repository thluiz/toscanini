import Config

config :toscanini,
  ecto_repos: [Toscanini.Repo],
  generators: [timestamp_type: :utc_datetime]

# Modelo dos dois passes da anotação automática (suggest + annotate). GPT dá
# cobertura/qualidade melhor que o modelo barato default do preset. Override em
# runtime via TOSCANINI_ANNOTATE_MODEL (ver config/runtime.exs).
config :toscanini,
  annotate_model: "openrouter/openai/gpt-5.2",
  annotate_fallback_models: ["openrouter/openai/gpt-5.1"]

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
  queues: [collectors: 3, digest: 1, default: 5, git_commit: 1, vox_publish: 1, transcribe: 2, feeds: 1],
  plugins: [
    # Varre assinaturas de feed de hora em hora (no minuto 0). O worker gateia
    # cada assinatura por janela quente/idle, então isto é barato (conditional GET).
    # Retenção: 1×/dia (04:30 UTC) apaga áudio local já arquivado no cold há >N dias.
    # O worker é auto-gated (enabled? + backlog_done + dry_run), então é no-op por padrão.
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Toscanini.Workers.FeedSweepWorker},
       {"30 4 * * *", Toscanini.Workers.RetentionSweepWorker}
     ]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
