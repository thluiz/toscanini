defmodule Toscanini.Repo do
  use Ecto.Repo,
    otp_app: :toscanini,
    adapter: Ecto.Adapters.SQLite3
end
