defmodule Toscanini.Pipeline.Dispatcher do
  alias Toscanini.{Repo, Pipeline}
  alias Toscanini.Workers

  @steps %{
    nil             => {:collect,                 Workers.CollectWorker,                :collectors},
    "collect"       => {:transcribe,              Workers.TranscribeWorker,             :transcribe},
    "transcribe"    => {:summarize,               Workers.SummarizeWorker,              :default},
    "summarize"     => {:annotate,                Workers.AnnotateWorker,               :default},
    # Etapa de anotação automática. No-op (só avança) se params.auto_annotate for
    # falso — a etapa existe no fluxo pra todos, mas só executa nos feeds marcados.
    "annotate"      => {:enrich_tags,             Workers.EnrichTagsWorker,             :default},
    "enrich_tags"   => {:write_files,             Workers.WriteFilesWorker,             :default},
    "write_files"   => {:git_commit,              Workers.GitCommitWorker,              :git_commit},
    "git_commit"    => {:s3_archive,              Workers.S3ArchiveWorker,              :default},
    "s3_archive"    => {:notify,                  Workers.NotifyWorker,                 :default},
    # Scholion quote publish flow (POST /publish/scholion)
    "scholion_queued"     => {:scholion_synthesize, Workers.ScholionSynthesizeWorker,   :default},
    "scholion_synthesize" => {:scholion_write,      Workers.ScholionWriteWorker,        :default},
    "scholion_write"      => {:scholion_commit,     Workers.ScholionCommitWorker,       :git_commit},
    "scholion_commit"     => {:notify,              Workers.NotifyWorker,               :default},
    # Scholion webclip flow (POST /publish/webclip). compose may park the
    # pipeline (status "parked") instead of failing — see Toscanini.Webclip.
    # compose and save share the serial :webclip queue (limit 1).
    "webclip_queued"  => {:webclip_compose, Workers.WebclipComposeWorker, :webclip},
    "webclip_compose" => {:webclip_save,    Workers.WebclipSaveWorker,    :webclip},
    "webclip_save"    => {:webclip_quotes,  Workers.WebclipQuotesWorker,  :default},
    "webclip_quotes"  => {:notify,          Workers.NotifyWorker,         :default},
    "notify"        => :done
  }

  @doc """
  Re-runs the pipeline's current step (used to resume a parked pipeline).
  `advance/1` runs the successor of `current_step`; this enqueues the worker
  of `current_step` itself.
  """
  def rerun(pipeline_id) do
    pipeline = Repo.get!(Pipeline, pipeline_id)

    entry =
      Enum.find(Map.values(@steps), fn
        {step, _worker, _queue} -> to_string(step) == pipeline.current_step
        :done -> false
      end)

    case entry do
      {step, worker, queue} -> enqueue(pipeline, step, worker, queue)
      nil -> {:error, "cannot rerun step: #{pipeline.current_step}"}
    end
  end

  def advance(pipeline_id) do
    pipeline = Repo.get!(Pipeline, pipeline_id)

    case Map.get(@steps, pipeline.current_step) do
      :done ->
        complete(pipeline)

      {step, worker, queue} ->
        enqueue(pipeline, step, worker, queue)

      nil ->
        {:error, "unknown step: #{pipeline.current_step}"}
    end
  end

  defp enqueue(pipeline, step, worker, queue) do
    pipeline
    |> Pipeline.changeset(%{current_step: to_string(step), status: "running"})
    |> Repo.update!()

    worker.new(%{"pipeline_id" => pipeline.id}, queue: queue) |> Oban.insert!()
    :ok
  end

  defp complete(pipeline) do
    pipeline
    |> Pipeline.changeset(%{status: "done", current_step: "done"})
    |> Repo.update!()
    :ok
  end
end
