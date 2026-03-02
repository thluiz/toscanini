defmodule ToscaniniWeb.HealthController do
  use ToscaniniWeb, :controller

  def index(conn, _params) do
    json(conn, %{ok: true, service: "toscanini"})
  end
end
