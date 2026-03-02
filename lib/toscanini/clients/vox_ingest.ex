defmodule Toscanini.Clients.VoxIngest do
  defp base_url, do: Application.fetch_env!(:toscanini, :base_url)

  def publish_json(path, json_data) do
    case Req.post("#{base_url()}/api/vox-ingest/publish-json",
           json: %{"path" => path, "json" => json_data, "notify" => false},
           receive_timeout: 900_000) do
      {:ok, %{status: s, body: body}} when s in [200, 201] -> {:ok, body}
      {:ok, %{status: s, body: body}} -> {:error, "vox-ingest HTTP #{s}: #{inspect(body)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end
end
