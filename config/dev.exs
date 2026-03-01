import Config

config :hermes_orchestrator, HermesOrchestratorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 8200],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "9uEf0n7sWrGuh0GWwveUmOmL52cx84f4x2L0Xa4X4ax0Cltf5A2qc3YjSQOMb56"

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
