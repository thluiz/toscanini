defmodule Toscanini.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Toscanini.ObanNotifier.attach()
    Toscanini.TranscribeFeeder.attach()

    children = [
      Toscanini.Repo,
      # Antes do Oban: jobs que ficaram executing num restart voltam para a fila.
      Toscanini.ObanRescue,
      # Depois do resgate, antes do Oban: todo transcribe available volta ao portão
      # e o feeder libera por lane (geral x lotes).
      Toscanini.TranscribeFeeder,
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
