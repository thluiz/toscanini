import Config

config :hermes_orchestrator,
  ecto_repos: [HermesOrchestrator.Repo],
  generators: [timestamp_type: :utc_datetime]

config :hermes_orchestrator, HermesOrchestratorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: HermesOrchestratorWeb.ErrorJSON],
    layout: false
  ],
  server: true

config :hermes_orchestrator, HermesOrchestrator.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: "/home/hermes/services/hermes_orchestrator/data/orchestrator.db"

config :hermes_orchestrator, Oban,
  engine: Oban.Engines.Lite,
  repo: HermesOrchestrator.Repo,
  queues: [collectors: 3, digest: 1, default: 5]

config :hermes_orchestrator, :base_url,
  System.get_env("HERMES_BASE_URL", "http://localhost:8080")

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
