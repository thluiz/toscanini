defmodule HermesOrchestratorWeb.HealthController do
  use HermesOrchestratorWeb, :controller

  def index(conn, _params) do
    json(conn, %{ok: true, service: "hermes-orchestrator"})
  end
end
