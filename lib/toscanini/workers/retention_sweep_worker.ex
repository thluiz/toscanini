defmodule Toscanini.Workers.RetentionSweepWorker do
  @moduledoc """
  Varredura diária de retenção: apaga o áudio LOCAL de episódios já arquivados no
  cold storage, liberando disco no `collected`.

  **Filesystem-driven** (não depende do banco de pipelines): varre
  `collected/*.json`, usa o `mtime` do áudio como idade (data do download) e apaga
  só com o objeto confirmado no S3. Cobre uniformemente tanto o backlog (arquivado
  pelo script standalone, sem registro no pipeline) quanto os episódios
  going-forward (arquivados pelo passo `s3_archive`).

  Disparado pelo `Oban.Plugins.Cron`. Auto-gated e conservador:

  1. No-op se `Archive.enabled?/0` for `false`.
  2. No-op se `TOSCANINI_ARCHIVE_BACKLOG_DONE != true` — trava operacional: nunca
     limpa antes de todo o histórico estar confirmado no cold (invariante do plano).
  3. Em `dry_run` (default `true`), só loga os candidatos — não apaga.
  4. **Nunca apaga sem confirmar o par no S3** (`Archive.object_exists?/1`):
     - podcast → `podcasts/<slug>.mp3` (o próprio mp3 no cold)
     - youtube → `youtube/<slug>.txt` (transcrição; o áudio local é re-baixável)
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger
  alias Toscanini.Archive
  alias Toscanini.Clients.GossipGate

  # Extensões de áudio possíveis (youtube via yt-dlp gera webm/m4a/opus/...).
  @audio_exts ~w[mp3 webm m4a opus mp4 ogg wav]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cfg = Archive.config()

    cond do
      not Archive.enabled?() ->
        Logger.info("[Retention] skip — arquivamento desligado")
        :ok

      cfg[:backlog_done] != true ->
        Logger.info("[Retention] skip — backlog não confirmado (TOSCANINI_ARCHIVE_BACKLOG_DONE)")
        :ok

      true ->
        sweep(cfg)
    end
  end

  defp sweep(cfg) do
    days   = cfg[:retention_days] || 30
    dry    = cfg[:dry_run] != false
    dir    = Application.get_env(:toscanini, :collected_dir, "/home/hermes/collected")
    cutoff = System.os_time(:second) - days * 86_400

    Logger.info("[Retention] início (dir=#{dir}, retention_days=#{days}, dry_run=#{dry})")

    {del, freed, kept, expired} =
      Path.wildcard(Path.join(dir, "*.json"))
      |> Enum.reduce({0, 0, 0, 0}, fn jf, acc -> process(jf, dir, cutoff, dry, acc) end)

    msg =
      "[Retention] fim — #{if dry, do: "DRY-RUN ", else: ""}vencidos=#{expired} " <>
        "apagados=#{del} liberado=#{gb(freed)}GB não-confirmados=#{kept}"

    Logger.info(msg)
    if not dry and del > 0, do: GossipGate.send("🧹 " <> msg)
    :ok
  end

  defp process(jf, dir, cutoff, dry, {del, freed, kept, expired}) do
    slug = Path.basename(jf, ".json")

    {audio, key} =
      case read_source(jf) do
        "youtube" -> {find_audio(dir, slug), "youtube/#{slug}.txt"}
        _         -> {Path.join(dir, "#{slug}.mp3"), "podcasts/#{slug}.mp3"}
      end

    cond do
      is_nil(audio) or not File.exists?(audio) ->
        # Já limpo ou nunca teve áudio local.
        {del, freed, kept, expired}

      mtime(audio) > cutoff ->
        # Ainda dentro da janela local de retenção.
        {del, freed, kept, expired}

      not Archive.object_exists?(key) ->
        Logger.warning("[Retention] mantém #{Path.basename(audio)} — objeto S3 não confirmado (#{key})")
        {del, freed, kept + 1, expired + 1}

      dry ->
        Logger.info("[Retention] WOULD delete #{audio} (#{mb(fsize(audio))}MB), s3=#{key}")
        {del, freed, kept, expired + 1}

      true ->
        size = fsize(audio)

        case File.rm(audio) do
          :ok ->
            Logger.info("[Retention] apagou #{audio} (#{mb(size)}MB), s3=#{key}")
            {del + 1, freed + size, kept, expired + 1}

          {:error, reason} ->
            Logger.error("[Retention] falha ao apagar #{audio}: #{inspect(reason)}")
            {del, freed, kept, expired + 1}
        end
    end
  end

  defp read_source(jf) do
    with {:ok, body} <- File.read(jf),
         {:ok, data} <- Jason.decode(body) do
      get_in(data, ["metadata", "source"])
    else
      _ -> nil
    end
  end

  defp find_audio(dir, slug) do
    Enum.find_value(@audio_exts, fn ext ->
      p = Path.join(dir, "#{slug}.#{ext}")
      if File.exists?(p), do: p
    end)
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> :infinity
    end
  end

  defp fsize(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  defp mb(bytes), do: div(bytes, 1_048_576)
  defp gb(bytes), do: Float.round(bytes / 1_073_741_824, 2)
end
