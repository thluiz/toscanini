defmodule HermesOrchestrator.Workers.SummarizeWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias HermesOrchestrator.{Repo, Pipeline, Pipeline.Dispatcher}
  alias HermesOrchestrator.Clients.VoxIntelligence

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline   = Repo.get!(Pipeline, pid)
    collect    = Pipeline.get_results(pipeline)["collect"]
    json_path  = collect["json"]
    json_data  = json_path |> File.read!() |> Jason.decode!()
    transcript = json_data["transcript"]
    metadata   = json_data["metadata"]
    timestamps = Pipeline.get_params(pipeline)["timestamps"] || []

    case VoxIntelligence.process_podcast(metadata, transcript, timestamps) do
      {:ok, result} ->
        json_data = Map.merge(json_data, result)
        File.write!(json_path, Jason.encode!(json_data, pretty: true))
        Pipeline.save_result(pipeline, "summarize", %{"done" => true})
        Dispatcher.advance(pid)
        :ok

      {:error, reason} ->
        Pipeline.fail(pipeline, reason)
        {:error, reason}
    end
  end
end
