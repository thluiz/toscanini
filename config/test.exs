import Config

config :toscanini, Toscanini.Repo,
  database: "/tmp/toscanini_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

config :toscanini, ToscaniniWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "testsecretkey1234567890testsecretkey1234567890testsecretkey12345678"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

