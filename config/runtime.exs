import Config

if config_env() == :prod do
  config :hermes_orchestrator, HermesOrchestratorWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 8200],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
