defmodule HermesOrchestrator.Clients.VoxIntelligence do
  defp base_url, do: Application.fetch_env!(:hermes_orchestrator, :base_url)

  def process_podcast(metadata, transcript, timestamps) do
    body = %{
      "transcript" => transcript,
      "timestamps" => timestamps || [],
      "metadata"   => metadata
    }

    case Req.post("#{base_url()}/api/vox-intelligence/presets/podcast/episode",
           json: body,
           receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      {:ok, %{status: s, body: b}} ->
        {:error, "vox-intelligence HTTP #{s}: #{inspect(b)}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end
end
