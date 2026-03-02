defmodule Toscanini.ObanNotifier do
  require Logger

  alias Toscanini.{Repo, Pipeline}
  alias Toscanini.Workers.BatchAdvanceWorker

  def attach do
    :telemetry.attach_many(
      "toscanini-oban-notifier",
      [
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  # Job descartado (esgotou tentativas)
  def handle_event([:oban, :job, :stop], _measurements, %{state: :discard, job: job}, _config) do
    notify_failure(job, "descartado (esgotou tentativas)")
    check_batch_on_failure(job)
  end

  # Exceção inesperada num job
  # Oban emite :exception (não :stop/:discard) para exceptions — verificar batch aqui também
  def handle_event([:oban, :job, :exception], _measurements, %{job: job, reason: reason}, _config) do
    error_text = Exception.format(:error, reason) |> String.slice(0, 400)
    notify_failure(job, "excepção: #{error_text}")
    # Avançar batch se foi a última tentativa
    if job.attempt >= job.max_attempts do
      check_batch_on_failure(job)
    end
  end

  def handle_event(_, _, _, _), do: :ok

  defp notify_failure(job, reason_label) do
    last_error =
      case List.last(job.errors) do
        nil -> "(sem detalhes)"
        err -> Map.get(err, "error", inspect(err)) |> String.slice(0, 600)
      end

    pipeline_id = Map.get(job.args, "pipeline_id", "—")

    msg = """
    <b>❌ Toscanini — falha no pipeline</b>

    <b>Pipeline:</b> <code>#{pipeline_id}</code>
    <b>Worker:</b> <code>#{job.worker}</code>
    <b>Tentativas:</b> #{job.attempt}/#{job.max_attempts}
    <b>Estado:</b> #{reason_label}

    <b>Erro:</b>
    <pre>#{html_escape(last_error)}</pre>
    """

    case Toscanini.Clients.GossipGate.send(String.trim(msg), "HTML") do
      :ok -> :ok
      {:error, e} -> Logger.warning("ObanNotifier: falha ao notificar GossipGate: #{inspect(e)}")
    end
  end

  # Se o job falhou e pertence a um batch, avança o batch mesmo em falha
  defp check_batch_on_failure(job) do
    with pipeline_id when not is_nil(pipeline_id) <- Map.get(job.args, "pipeline_id"),
         pipeline when not is_nil(pipeline) <- Repo.get(Pipeline, pipeline_id),
         params = Pipeline.get_params(pipeline),
         batch_id when not is_nil(batch_id) <- params["batch_id"],
         item_id when not is_nil(item_id) <- params["batch_item_id"] do
      last_error =
        case List.last(job.errors) do
          nil -> nil
          err -> Map.get(err, "error", inspect(err)) |> String.slice(0, 300)
        end

      BatchAdvanceWorker.new(%{
        "batch_id"      => batch_id,
        "batch_item_id" => item_id,
        "result"        => "error",
        "error"         => last_error
      })
      |> Oban.insert!()
    else
      _ -> :ok
    end
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
