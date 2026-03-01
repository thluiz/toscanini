defmodule HermesOrchestrator.Clients.GossipGate do
  defp base_url, do: Application.fetch_env!(:hermes_orchestrator, :base_url)

  def send(message, parse_mode \\ "HTML") do
    case Req.post("#{base_url()}/api/gossip-gate/send",
           json: %{"message" => message, "parse_mode" => parse_mode}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}}   -> {:error, "gossip-gate HTTP #{s}"}
      {:error, e}           -> {:error, inspect(e)}
    end
  end
end
