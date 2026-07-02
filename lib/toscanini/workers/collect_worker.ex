defmodule Toscanini.Workers.CollectWorker do
  use Oban.Worker, queue: :collectors, max_attempts: 3

  require Logger
  alias Toscanini.{Repo, Pipeline, Pipelines, Pipeline.Dispatcher}

  # Backoff longo para falhas transientes da API PocketCasts ("não encontrado
  # no feed"): em vez de bloquear o worker com Process.sleep (o que seguraria um
  # slot da fila :collectors), reagenda um NOVO job com schedule_in. O job actual
  # termina com :ok e liberta o slot na hora; a fila continua a coletar outros
  # episódios. 1ª nova tentativa em 30min, 2ª em 1h, depois falha de vez.
  @feed_retry_delays [1800, 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_id" => pid} = args}) do
    pipeline   = Repo.get!(Pipeline, pid)
    collector  = Pipelines.collector(pipeline.collector)
    params     = Pipeline.get_params(pipeline)
    feed_retry = Map.get(args, "feed_retry", 0)

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

      # Falha transitória conhecida da API PocketCasts: lista de episódios veio
      # truncada/em cache. Reagenda (30min, depois 1h) sem segurar a fila.
      {:error, {:transient_feed, msg}} ->
        case Enum.at(@feed_retry_delays, feed_retry) do
          nil ->
            # Esgotou as re-tentativas longas → falha definitiva (notifica).
            Pipeline.fail(pipeline, msg)
            {:error, msg}

          delay ->
            Logger.info(
              "[CollectWorker] #{pid}: feed transitório, reagendando colecta em #{delay}s (tentativa longa #{feed_retry + 1}/#{length(@feed_retry_delays)})"
            )

            mark_retrying(pipeline, msg)

            __MODULE__.new(
              %{"pipeline_id" => pid, "feed_retry" => feed_retry + 1},
              schedule_in: delay,
              max_attempts: 1
            )
            |> Oban.insert!()

            :ok
        end

      {:error, reason} ->
        Pipeline.fail(pipeline, reason)
        {:error, reason}
    end
  end

  # Marca o pipeline como "retrying" enquanto espera a re-tentativa longa, para
  # não aparecer como "failed" no dashboard durante a janela de backoff.
  defp mark_retrying(pipeline, msg) do
    pipeline
    |> Pipeline.changeset(%{status: "retrying", error: msg})
    |> Repo.update!()
  end
end
