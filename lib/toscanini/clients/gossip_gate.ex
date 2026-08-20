defmodule Toscanini.Clients.GossipGate do
  @moduledoc """
  Cliente do GossipGate.

  O GossipGate resolve `target` contra um registry de destinos nomeados
  (`destinations.json`), cada um com o seu `chat_id`. Todas as notificações do
  Toscanini vão para o destino `toscanini` — o chat próprio de processamento —
  em vez do chat geral. Para mudar sem redeploy: `GOSSIPGATE_TARGET`.
  """

  defp base_url, do: Application.fetch_env!(:toscanini, :base_url)
  defp api_key,  do: Application.fetch_env!(:toscanini, :gossipgate_api_key)
  defp default_target, do: Application.get_env(:toscanini, :gossipgate_target, "toscanini")

  def send(message, parse_mode \\ "HTML", target \\ nil) do
    target = target || default_target()

    case Req.post("#{base_url()}/api/gossip-gate/send",
           headers: [{"x-api-key", api_key()}],
           json: %{"message" => message, "parse_mode" => parse_mode, "target" => target}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}}   -> {:error, "gossip-gate HTTP #{s} (target=#{target})"}
      {:error, e}           -> {:error, inspect(e)}
    end
  end
end
