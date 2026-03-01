import Config

config :hermes_orchestrator, HermesOrchestrator.Repo,
  database: "/tmp/hermes_orchestrator_test.db"

config :hermes_orchestrator, HermesOrchestratorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "testsecretkey1234567890testsecretkey1234567890testsecretkey12345678"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
