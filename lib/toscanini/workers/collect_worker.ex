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

        slug  = result["slug"]
        force = params["force_retranscribe"] == true

        if not force and slug != nil and slug != "" do
          case Pipeline.find_duplicate_by_slug(slug, pid) do
            nil ->
              Dispatcher.advance(pid)

            existing_id ->
              Pipeline.mark_duplicate(pipeline, existing_id)
          end
        else
          Dispatcher.advance(pid)
        end

        :ok

      {:error, reason} ->
        Pipeline.fail(pipeline, reason)
        {:error, reason}
    end
  end
end
