defmodule Toscanini.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Toscanini.ObanNotifier.attach()

    children = [
      Toscanini.Repo,
      {Oban, Application.fetch_env!(:toscanini, Oban)},
      ToscaniniWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Toscanini.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ToscaniniWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
