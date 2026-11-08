defmodule Toscanini.GpuCooldown do
  @moduledoc """
  Disjuntor da GPU do Whisper.

  Quando o whisper aborta na GPU (exit 134: `CUDA failed with error out of memory`,
  que derruba o processo inteiro e não deixa o fallback em Python rodar), o
  `TranscribeWorker` grava `data/gpu_cooldown.json` com um horário `until`.
  Enquanto ele não passa, `priv/whisper_worker.py` (`select_model/0`) manda todo
  job para a CPU. Passado o horário, o próximo job tenta a GPU de novo.
  """

  @cooldown_secs 15 * 60

  def cooldown_secs, do: @cooldown_secs

  @doc "Abre o cooldown: a GPU fica fora até `now + 15 min`. Devolve o horário (epoch)."
  def start(path \\ default_path(), now \\ System.os_time(:second)) do
    until = now + @cooldown_secs
    body = Jason.encode!(%{"until" => until, "started_at" => now})
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, body)
    File.rename!(tmp, path)
    until
  end

  @doc "A GPU está em cooldown agora?"
  def active?(path \\ default_path(), now \\ System.os_time(:second)) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"until" => until}} when is_integer(until) <- Jason.decode(raw) do
      until > now
    else
      _ -> false
    end
  end

  defp default_path,
    do: Path.join(Application.get_env(:toscanini, :data_dir, "data"), "gpu_cooldown.json")
end
