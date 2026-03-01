defmodule HermesOrchestrator.Clients.Whisper do
  defp base_url, do: Application.fetch_env!(:hermes_orchestrator, :base_url)

  def submit(mp3_path) do
    tmp = "/tmp/upload_#{System.unique_integer([:positive])}.mp3"

    try do
      File.cp!(mp3_path, tmp)
      content = File.read!(tmp)

      case Req.post("#{base_url()}/api/whisper/transcribe",
             form: [file: {content, filename: "upload.mp3", content_type: "audio/mpeg"}]) do
        {:ok, %{status: 200, body: %{"job_id" => wjid}}} ->
          {:ok, wjid}

        {:ok, %{status: s, body: b}} ->
          {:error, "whisper submit HTTP #{s}: #{inspect(b)}"}

        {:error, e} ->
          {:error, inspect(e)}
      end
    after
      File.rm(tmp)
    end
  end

  def status(whisper_job_id) do
    case Req.get("#{base_url()}/api/whisper/status/#{whisper_job_id}") do
      {:ok, %{body: %{"status" => "completed", "result" => t}}} ->
        {:completed, t}

      {:ok, %{body: %{"status" => s, "progress" => pct}}}
      when s in ["queued", "processing"] ->
        {:processing, pct}

      {:ok, %{body: %{"status" => s}}}
      when s in ["queued", "processing"] ->
        {:processing, 0}

      {:ok, %{body: %{"status" => "failed"}}} ->
        {:failed, "whisper failed"}

      {:error, e} ->
        {:failed, inspect(e)}
    end
  end
end
