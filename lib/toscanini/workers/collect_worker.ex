defmodule Toscanini.Workers.CollectWorker do
  use Oban.Worker, queue: :collectors, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipelines, Pipeline.Dispatcher}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline  = Repo.get!(Pipeline, pid)
    collector = Pipelines.collector(pipeline.collector)
    params    = Pipeline.get_params(pipeline)

    case collector.collect(params["url"]) do
      {:ok, result} ->
        Pipeline.save_result(pipeline, "collect", result)
        Dispatcher.advance(pid)
        :ok

      {:error, reason} ->
        Pipeline.fail(pipeline, reason)
        {:error, reason}
    end
  end
end
