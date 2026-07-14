import Config

# Database — path relativo ao WorkingDirectory do serviço por padrão.
# Para mover o banco: setar TOSCANINI_DB_PATH no service file. Zero toque em Elixir.
db_path = System.get_env("TOSCANINI_DB_PATH", "data/orchestrator.db")

config :toscanini, Toscanini.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: db_path

# Diretório de saída para MP3 e JSON coletados.
# Para mover: setar TOSCANINI_COLLECTED_DIR no service file.
config :toscanini, :collected_dir,
  System.get_env("TOSCANINI_COLLECTED_DIR", "/home/hermes/collected")

# API key do GossipGate para notificações Telegram.
config :toscanini, :gossipgate_api_key,
  System.get_env("GOSSIPGATE_API_KEY", "")

# URL base dos serviços internos (via nginx). Nunca exposta em código.
# Para apontar para outro host: setar HERMES_BASE_URL no service file.
config :toscanini, :base_url,
  System.get_env("HERMES_BASE_URL", "http://localhost:8080")

if config_env() == :prod do
  config :toscanini, ToscaniniWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 8200],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end

# URL pública do Vox (ex: https://vox.thluiz.com)
config :toscanini, :vox_base_url,
  System.get_env("VOX_BASE_URL", "https://vox.thluiz.com")

# URL pública do Scholion (para o link nas notificações de nota publicada)
config :toscanini, :scholion_base_url,
  System.get_env("SCHOLION_BASE_URL", "https://scholion.thluiz.com")

# Token da app do Facebook (formato APP_ID|APP_SECRET) para recrawl de previews
config :toscanini, :facebook_app_token,
  System.get_env("FACEBOOK_APP_TOKEN", "")

# Segundos a aguardar após vox_publish antes de chamar o Facebook (CDN delay)
config :toscanini, :facebook_cache_refresh_delay,
  System.get_env("FACEBOOK_REFRESH_DELAY", "120") |> String.to_integer()

# Arquivamento em cold storage (S3). Desligado por padrão — o passo s3_archive é
# no-op até TOSCANINI_ARCHIVE_ENABLED=true E um bucket configurado. Ver
# Toscanini.Archive / Toscanini.Workers.S3ArchiveWorker.
config :toscanini, :archive,
  enabled:        System.get_env("TOSCANINI_ARCHIVE_ENABLED", "false") == "true",
  bucket:         System.get_env("TOSCANINI_ARCHIVE_BUCKET", ""),
  region:         System.get_env("TOSCANINI_ARCHIVE_REGION", "us-east-1"),
  storage_class:  System.get_env("TOSCANINI_ARCHIVE_STORAGE_CLASS", "DEEP_ARCHIVE"),
  retention_days: System.get_env("TOSCANINI_ARCHIVE_RETENTION_DAYS", "30") |> String.to_integer(),
  dry_run:        System.get_env("TOSCANINI_ARCHIVE_DRY_RUN", "true") == "true",
  backlog_done:   System.get_env("TOSCANINI_ARCHIVE_BACKLOG_DONE", "false") == "true",
  aws_bin:        System.get_env("TOSCANINI_AWS_BIN", "aws"),
  profile:        System.get_env("AWS_PROFILE", "")

# Whisper worker — paths configuráveis via env (sem paths hardcoded no código)
config :toscanini, :whisper_python_path,
  System.fetch_env!("WHISPER_PYTHON_PATH")

config :toscanini, :whisper_worker_path,
  System.fetch_env!("WHISPER_WORKER_PATH")

config :toscanini, :whisper_ld_library_path,
  System.get_env("WHISPER_LD_LIBRARY_PATH", "")
