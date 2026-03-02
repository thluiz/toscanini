defmodule Toscanini.Clients.GossipGate do
  defp base_url, do: Application.fetch_env!(:toscanini, :base_url)
  defp api_key,  do: Application.fetch_env!(:toscanini, :gossipgate_api_key)

  def send(message, parse_mode \\ "HTML") do
    case Req.post("#{base_url()}/api/gossip-gate/send",
           headers: [{"x-api-key", api_key()}],
           json: %{"message" => message, "parse_mode" => parse_mode}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}}   -> {:error, "gossip-gate HTTP #{s}"}
      {:error, e}           -> {:error, inspect(e)}
    end
  end
end
