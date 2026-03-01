defmodule HermesOrchestrator.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HermesOrchestrator.Repo,
      {Oban, Application.fetch_env!(:hermes_orchestrator, Oban)},
      HermesOrchestratorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: HermesOrchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HermesOrchestratorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
