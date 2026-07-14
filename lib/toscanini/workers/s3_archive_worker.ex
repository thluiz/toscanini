defmodule Toscanini.Workers.S3ArchiveWorker do
  @moduledoc """
  Passo `s3_archive` do pipeline (entre `git_commit` e `notify`). Arquiva o
  áudio/transcrição no cold storage assim que o episódio é publicado — backup
  desde o dia 1. NÃO apaga nada local (a limpeza é do `RetentionSweepWorker`,
  aos N dias, só com o objeto confirmado no S3).

  - **Podcast** (`metadata.source != "youtube"`): sobe o MP3 →
    `podcasts/<slug>.mp3` na storage class de arquivamento (Deep Archive).
  - **YouTube**: sobe só a transcrição → `youtube/<slug>.txt` (STANDARD); o áudio
    é re-baixável do YouTube.

  Quando `Archive.enabled?/0` é `false`, é no-op (pass-through) — seguro pra
  rodar sem credencial / flag off.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, Archive}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline = Repo.get!(Pipeline, pid)

    if Archive.enabled?() do
      archive(pipeline, pid)
    else
      pass_through(pipeline, pid, "disabled")
    end
  end

  defp archive(pipeline, pid) do
    collect = Pipeline.get_results(pipeline)["collect"] || %{}
    slug    = collect["slug"]
    json    = collect["json"]

    result =
      case detect_source(pipeline, json) do
        "youtube" -> archive_youtube(json, slug)
        _         -> archive_podcast(collect, slug)
      end

    case result do
      {:ok, info} ->
        stamped = Map.merge(%{"done" => true, "archived_at" => now_iso()}, info)
        Pipeline.save_result(pipeline, "s3_archive", stamped)
        Dispatcher.advance(pid)
        :ok

      {:skip, reason} ->
        Logger.warning("[S3Archive] #{pid}: skip (#{reason})")
        Pipeline.save_result(pipeline, "s3_archive", %{"done" => false, "skipped" => reason})
        Dispatcher.advance(pid)
        :ok

      {:error, reason} ->
        Logger.error("[S3Archive] #{pid}: #{reason}")
        {:error, reason}
    end
  end

  defp pass_through(pipeline, pid, reason) do
    Pipeline.save_result(pipeline, "s3_archive", %{"done" => false, "skipped" => reason})
    Dispatcher.advance(pid)
    :ok
  end

  # Fonte autoritativa: metadata.source no JSON; fallback pro collector do pipeline.
  defp detect_source(pipeline, json) do
    from_json =
      with path when is_binary(path) <- json,
           {:ok, body} <- File.read(path),
           {:ok, data} <- Jason.decode(body) do
        get_in(data, ["metadata", "source"])
      else
        _ -> nil
      end

    from_json || pipeline.collector
  end

  defp archive_podcast(collect, slug) do
    mp3 = collect["mp3"] || collect["audio"]

    cond do
      is_nil(slug) or slug == "" -> {:skip, "sem-slug"}
      is_nil(mp3) or not File.exists?(mp3) -> {:skip, "mp3-inexistente"}
      true -> do_put(mp3, "podcasts/#{slug}.mp3", storage_class(), "podcast")
    end
  end

  defp archive_youtube(json, slug) do
    with path when is_binary(path) <- json,
         {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body),
         transcript when is_binary(transcript) and transcript != "" <- data["transcript"] do
      key = "youtube/#{slug}.txt"

      if Archive.object_exists?(key) do
        {:ok, reused("youtube", key, "STANDARD")}
      else
        tmp = Path.join(System.tmp_dir!(), "arch_#{slug}.txt")
        File.write!(tmp, transcript)

        try do
          case Archive.put(tmp, key, "STANDARD") do
            {:ok, _} -> {:ok, %{"kind" => "youtube", "s3_key" => key, "storage_class" => "STANDARD"}}
            err      -> err
          end
        after
          File.rm(tmp)
        end
      end
    else
      _ -> {:skip, "transcript-vazio"}
    end
  end

  defp do_put(local, key, sc, kind) do
    if Archive.object_exists?(key) do
      {:ok, reused(kind, key, sc)}
    else
      case Archive.put(local, key, sc) do
        {:ok, _} -> {:ok, %{"kind" => kind, "s3_key" => key, "storage_class" => sc}}
        err      -> err
      end
    end
  end

  defp reused(kind, key, sc),
    do: %{"kind" => kind, "s3_key" => key, "storage_class" => sc, "reused" => true}

  defp storage_class, do: to_string(Archive.config()[:storage_class] || "DEEP_ARCHIVE")

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
