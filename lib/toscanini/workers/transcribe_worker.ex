defmodule Toscanini.Workers.TranscribeWorker do
  use Oban.Worker, queue: :transcribe, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @min_chars_per_sec 3

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    apply_queue_concurrency(:transcribe)
    pipeline      = Repo.get!(Pipeline, pid)
    params        = Pipeline.get_params(pipeline)
    collect       = Pipeline.get_results(pipeline)["collect"]
    json_path     = collect["json"]
    json_data     = json_path |> File.read!() |> Jason.decode!()
    transcript    = json_data["transcript"]
    duration_secs = collect["duration_secs"] || 0
    force         = params["force_retranscribe"] == true

    if not force and valid_transcript?(transcript, duration_secs) do
      Pipeline.save_result(pipeline, "transcribe", %{"skipped" => true, "reason" => "existing transcript"})
      Dispatcher.advance(pid)
      :ok
    else
      run_transcription(pipeline, collect["mp3"], json_path, json_data)
    end
  end

  defp run_transcription(pipeline, mp3_path, json_path, json_data) do
    python_path   = Application.fetch_env!(:toscanini, :whisper_python_path)
    worker_path   = Application.fetch_env!(:toscanini, :whisper_worker_path)
    ld_lib_path   = Application.get_env(:toscanini, :whisper_ld_library_path, "")

    job_dir       = "/tmp/whisper-#{pipeline.id}"
    output_path   = Path.join(job_dir, "output.txt")
    progress_path = Path.join(job_dir, "progress.txt")
    File.mkdir_p!(job_dir)

    cores = get_current_cores(:transcribe)

    try do
      env = if ld_lib_path != "", do: [{"LD_LIBRARY_PATH", ld_lib_path}], else: []

      args = [worker_path, mp3_path, output_path, progress_path] ++
        if cores, do: [Integer.to_string(cores)], else: []

      {_stdout, exit_code} = System.cmd(
        python_path,
        args,
        env: env
      )

      if exit_code != 0 do
        {:error, "whisper worker exited with code #{exit_code}"}
      else
        case File.read(output_path) do
          {:ok, transcript} ->
            word_count = transcript |> String.split() |> length()

            if word_count < 50 do
              {:error, "Insufficient transcription: #{word_count} words (minimum: 50)"}
            else
              updated = Map.put(json_data, "transcript", transcript)
              File.write!(json_path, Jason.encode!(updated, pretty: true))
              Pipeline.save_result(pipeline, "transcribe", %{"done" => true})
              Dispatcher.advance(pipeline.id)
              :ok
            end

          {:error, reason} ->
            {:error, "output.txt not found after worker completed: #{reason}"}
        end
      end
    after
      File.rm_rf(job_dir)
    end
  end

  defp valid_transcript?(transcript, duration_secs) do
    is_binary(transcript) and
      byte_size(transcript) >= duration_secs * @min_chars_per_sec
  end

  @default_cores 14

  defp get_current_cores(queue) do
    path = Path.join(Application.get_env(:toscanini, :data_dir, "data"), "queue_schedules.json")
    hour = Time.utc_now().hour
    with {:ok, raw} <- File.read(path),
         {:ok, schedules} <- Jason.decode(raw),
         windows when is_list(windows) <- schedules[Atom.to_string(queue)] do
      case Enum.find(windows, fn %{"from" => f, "to" => t} -> hour >= f and hour < t end) do
        %{"cores" => cores} when is_integer(cores) -> cores
        _ -> @default_cores
      end
    else
      _ -> @default_cores
    end
  end

  defp apply_queue_concurrency(queue) do
    path = Path.join(Application.get_env(:toscanini, :data_dir, "data"), "queue_schedules.json")
    hour = Time.utc_now().hour
    with {:ok, raw} <- File.read(path),
         {:ok, schedules} <- Jason.decode(raw),
         windows when is_list(windows) <- schedules[Atom.to_string(queue)] do
      case Enum.find(windows, fn %{"from" => f, "to" => t} -> hour >= f and hour < t end) do
        %{"limit" => limit} -> Oban.scale_queue(queue: queue, limit: limit)
        nil -> :ok
      end
    else
      _ -> :ok
    end
  end
end
