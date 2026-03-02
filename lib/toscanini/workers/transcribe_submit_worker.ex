defmodule Toscanini.Workers.TranscribeSubmitWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline}
  alias Toscanini.{Clients.Whisper, Workers.TranscribePollWorker}
  alias Toscanini.Pipeline.Dispatcher

  @min_chars_per_sec 3

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline  = Repo.get!(Pipeline, pid)
    params    = Pipeline.get_params(pipeline)
    collect   = Pipeline.get_results(pipeline)["collect"]
    json_path = collect["json"]
    json_data = json_path |> File.read!() |> Jason.decode!()

    transcript    = json_data["transcript"]
    duration_secs = collect["duration_secs"] || 0
    force         = params["force_retranscribe"] == true

    if not force and valid_transcript?(transcript, duration_secs) do
      Pipeline.save_result(pipeline, "transcribe", %{"skipped" => true, "reason" => "existing transcript"})
      Dispatcher.advance(pid)
      :ok
    else
      mp3_path = collect["mp3"]
      duration = collect["duration_secs"] || 7200

      deadline =
        DateTime.utc_now()
        |> DateTime.add(div(duration, 4) + 600, :second)
        |> DateTime.to_iso8601()

      case Whisper.submit(mp3_path) do
        {:ok, wjid} ->
          Pipeline.save_result(pipeline, "transcribe_submitted", %{"whisper_job_id" => wjid})

          TranscribePollWorker.new(
            %{"pipeline_id" => pid, "whisper_job_id" => wjid, "deadline" => deadline},
            schedule_in: 30
          )
          |> Oban.insert!()

          :ok

        {:error, reason} ->
          Pipeline.fail(pipeline, reason)
          {:error, reason}
      end
    end
  end

  defp valid_transcript?(transcript, duration_secs) do
    is_binary(transcript) and
      byte_size(transcript) >= duration_secs * @min_chars_per_sec
  end
end
