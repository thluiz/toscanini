defmodule HermesOrchestrator.Repo do
  use Ecto.Repo,
    otp_app: :hermes_orchestrator,
    adapter: Ecto.Adapters.SQLite3
end
