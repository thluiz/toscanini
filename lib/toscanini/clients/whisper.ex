defmodule Toscanini.Clients.Whisper do
  defp base_url, do: Application.fetch_env!(:toscanini, :base_url)

  # Usa curl para upload multipart — Req.form não suporta ficheiros binários.
  # Gotcha: vírgulas no nome do ficheiro quebram curl multipart → sempre /tmp/upload_N.mp3
  def submit(mp3_path) do
    tmp = "/tmp/upload_#{System.unique_integer([:positive])}.mp3"

    try do
      File.cp!(mp3_path, tmp)
      url = "#{base_url()}/api/whisper/transcribe"

      case System.cmd("curl", ["-s", "-F", "file=@#{tmp};type=audio/mpeg", url]) do
        {body, 0} ->
          case Jason.decode(body) do
            {:ok, %{"job_id" => wjid}} -> {:ok, wjid}
            {:ok, %{"jobId" => wjid}}  -> {:ok, wjid}
            {:ok, resp}                -> {:error, "whisper: resposta inesperada: #{inspect(resp)}"}
            {:error, _}                -> {:error, "whisper: resposta inválida: #{body}"}
          end

        {out, code} ->
          {:error, "curl exit #{code}: #{out}"}
      end
    after
      File.rm(tmp)
    end
  end

  def status(whisper_job_id) do
    case Req.get("#{base_url()}/api/whisper/status/#{whisper_job_id}") do
      {:ok, %{body: %{"status" => "completed"}}} ->
        fetch_result(whisper_job_id)

      {:ok, %{body: %{"status" => s}}} when s in ["queued", "processing"] ->
        {:processing, 0}

      {:ok, %{body: %{"status" => "failed"}}} ->
        {:failed, "whisper failed"}

      {:ok, %{body: %{"error" => "Job not found"}}} ->
        # Status expirou — tenta buscar o resultado directamente
        fetch_result(whisper_job_id)

      {:ok, %{body: b}} ->
        {:failed, "whisper: status desconhecido: #{inspect(b)}"}

      {:error, e} ->
        {:failed, inspect(e)}
    end
  end

  defp fetch_result(whisper_job_id) do
    case Req.get("#{base_url()}/api/whisper/result/#{whisper_job_id}") do
      {:ok, %{status: 200, body: transcript}} when is_binary(transcript) ->
        {:completed, transcript}

      {:ok, %{status: s}} ->
        {:failed, "whisper result HTTP #{s}"}

      {:error, e} ->
        {:failed, inspect(e)}
    end
  end
end
