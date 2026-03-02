defmodule Toscanini.Pipeline.Dispatcher do
  alias Toscanini.{Repo, Pipeline}
  alias Toscanini.Workers

  @steps %{
    nil             => {:collect,     Workers.CollectWorker,          :collectors},
    "collect"       => {:transcribe,  Workers.TranscribeSubmitWorker, :default},
    "transcribe"    => {:summarize,   Workers.SummarizeWorker,        :default},
    "summarize"     => {:enrich_tags, Workers.EnrichTagsWorker,       :default},
    "enrich_tags"   => {:publish,     Workers.PublishWorker,          :default},
    "publish"       => {:notify,      Workers.NotifyWorker,           :default},
    "notify"        => :done
  }

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
