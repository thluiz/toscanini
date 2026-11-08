defmodule Toscanini.Workers.TranscribeWorker do
  use Oban.Worker, queue: :transcribe, max_attempts: 3

  require Logger

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, TranscriptCheck, Clients.GossipGate}
  alias Toscanini.{GpuCooldown, Scheduler}

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
      audio_path = collect["audio"] || collect["mp3"]
      run_transcription(pipeline, audio_path, json_path, json_data, duration_secs)
    end
  end

  defp run_transcription(pipeline, mp3_path, json_path, json_data, duration_secs) do
    python_path   = Application.fetch_env!(:toscanini, :whisper_python_path)
    worker_path   = Application.fetch_env!(:toscanini, :whisper_worker_path)
    ld_lib_path   = Application.get_env(:toscanini, :whisper_ld_library_path, "")

    job_dir       = "/tmp/whisper-#{pipeline.id}"
    output_path   = Path.join(job_dir, "output.txt")
    progress_path = Path.join(job_dir, "progress.txt")
    File.mkdir_p!(job_dir)

    cores = get_current_cores(:transcribe)
    # Fotografia de antes do run: se a GPU era candidata, um abort (134) é dela.
    gpu_expected? = gpu_expected?()

    try do
      env = if ld_lib_path != "", do: [{"LD_LIBRARY_PATH", ld_lib_path}], else: []

      args = [worker_path, mp3_path, output_path, progress_path] ++
        if cores, do: [Integer.to_string(cores)], else: []

      {_stdout, exit_code} = System.cmd(
        python_path,
        args,
        env: env
      )

      case classify_exit(exit_code, gpu_expected?) do
        :gpu_abort ->
          gpu_aborted(pipeline)

        {:error, _reason} = error ->
          error

        :ok ->
          case File.read(output_path) do
            {:ok, transcript} ->
              word_count = transcript |> String.split() |> length()

              if word_count < 50 do
                {:error, "Insufficient transcription: #{word_count} words (minimum: 50)"}
              else
                case TranscriptCheck.check(transcript, duration_secs) do
                  :ok ->
                    updated = Map.put(json_data, "transcript", transcript)
                    File.write!(json_path, Jason.encode!(updated, pretty: true))
                    Pipeline.save_result(pipeline, "transcribe", %{"done" => true})
                    Dispatcher.advance(pipeline.id)
                    :ok

                  {:error, reason} ->
                    reject_degenerate(pipeline, reason)
                end
              end

            {:error, reason} ->
              {:error, "output.txt not found after worker completed: #{reason}"}
          end
      end
    after
      File.rm_rf(job_dir)
    end
  end

  @gpu_abort_exit 134
  @gpu_abort_snooze_secs 10

  @doc false
  # Exit 134 (SIGABRT) é o `CUDA failed with error out of memory` do CTranslate2:
  # o processo inteiro cai e o fallback em Python nunca roda. Só vale como "GPU
  # estourou" se a GPU era candidata nesse run; fora disso é erro comum (conta
  # tentativa).
  def classify_exit(0, _gpu_expected?), do: :ok
  def classify_exit(@gpu_abort_exit, true), do: :gpu_abort
  def classify_exit(exit_code, _gpu_expected?), do: {:error, "whisper worker exited with code #{exit_code}"}

  # A GPU só entra no run se a janela atual permite e não há cooldown aberto
  # (mesma regra de `select_model/0` em priv/whisper_worker.py).
  defp gpu_expected? do
    case Scheduler.current_window(:transcribe) do
      %{"gpu" => true} -> not GpuCooldown.active?()
      _ -> false
    end
  end

  # Abre o cooldown e devolve o job à fila sem gastar tentativa (snooze): o
  # próximo run vê o cooldown e vai para a CPU.
  defp gpu_aborted(pipeline) do
    until = GpuCooldown.start()

    Logger.warning(
      "[TranscribeWorker] #{pipeline.id}: whisper abortou na GPU (exit #{@gpu_abort_exit}); " <>
        "GPU em cooldown por #{div(GpuCooldown.cooldown_secs(), 60)} min (até #{until}), job volta à fila"
    )

    {:snooze, @gpu_abort_snooze_secs}
  end

  # Retentar não adianta (o Whisper repete o mesmo resultado e cada rodada custa
  # até ~40min de CPU): falha o pipeline na hora e avisa. O transcript no JSON
  # fica intocado, então nada degenerado chega ao summarize/Vox.
  defp reject_degenerate(pipeline, reason) do
    Logger.warning("[TranscribeWorker] #{pipeline.id}: #{reason}")
    Pipeline.fail(pipeline, reason)

    msg = """
    <b>⚠️ Toscanini — transcrição rejeitada</b>

    <b>Pipeline:</b> <code>#{pipeline.id}</code>
    <b>Episódio:</b> #{html_escape(Pipeline.get_results(pipeline)["collect"]["title"] || "—")}
    <b>Motivo:</b> #{html_escape(reason)}
    """

    GossipGate.send(String.trim(msg), "HTML")
    {:cancel, reason}
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp valid_transcript?(transcript, duration_secs) do
    is_binary(transcript) and
      byte_size(transcript) >= duration_secs * @min_chars_per_sec
  end

  @default_cores 14

  defp get_current_cores(queue) do
    case Scheduler.current_window(queue) do
      %{"cores" => cores} when is_integer(cores) -> cores
      _ -> @default_cores
    end
  end

  defp apply_queue_concurrency(queue) do
    case Scheduler.current_window(queue) do
      %{"limit" => limit} -> Oban.scale_queue(queue: queue, limit: limit)
      _ -> :ok
    end
  end
end
