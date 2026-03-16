defmodule Toscanini.Workers.TranscribePollWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.Whisper

  # Deadline is kept in args for backwards compatibility with in-flight jobs
  # but is no longer enforced — if whisper is stuck, investigate rather than fail.
  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid, "whisper_job_id" => wjid} = _args}) do
    case Whisper.status(wjid) do
      {:completed, transcript} ->
        pipeline = Repo.get!(Pipeline, pid)

        if pipeline.status == "cancelled" do
          :ok
        else
          json_path = Pipeline.get_results(pipeline) |> get_in(["collect", "json"])

          json_data = json_path |> File.read!() |> Jason.decode!()
          json_data = Map.put(json_data, "transcript", transcript)
          File.write!(json_path, Jason.encode!(json_data, pretty: true))

          Pipeline.save_result(pipeline, "transcribe", %{"done" => true})
          Dispatcher.advance(pid)
          :ok
        end

      {:processing, pct} ->
        interval =
          cond do
            pct < 50 -> 30
            pct < 85 -> 20
            true     -> 10
          end

        __MODULE__.new(
          %{"pipeline_id" => pid, "whisper_job_id" => wjid},
          schedule_in: interval
        )
        |> Oban.insert!()

        :ok

      {:failed, reason} ->
        Repo.get!(Pipeline, pid) |> Pipeline.fail(reason)
        {:error, reason}
    end
  end
end
