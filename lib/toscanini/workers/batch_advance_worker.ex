defmodule Toscanini.Workers.BatchAdvanceWorker do
  use Oban.Worker, queue: :digest, max_attempts: 3

  require Logger

  alias Toscanini.{Repo, Pipeline, Batches, Batch}
  alias Toscanini.Pipeline.Dispatcher
  alias Toscanini.Clients.GossipGate

  @impl Oban.Worker
  def perform(%{args: %{"batch_id" => batch_id, "batch_item_id" => item_id} = args}) do
    item = Batches.get_item!(item_id)

    # Marcar item atual como done ou failed
    if args["result"] == "ok" do
      Batches.mark_item_done(item)
    else
      Batches.mark_item_failed(item, args["error"])
    end

    # Reler batch com contadores atualizados
    batch = Batches.get_batch!(batch_id)

    if batch.status == "done" do
      send_summary(batch)
    else
      case Batches.next_pending_item(batch_id) do
        nil ->
          # Nenhum pendente — outro item ainda em execução (não devia acontecer
          # em batch serial, mas tratado com segurança)
          :ok

        next_item ->
          submit_next(batch, next_item)
      end
    end

    :ok
  end

  defp submit_next(batch, item) do
    extra       = Batch.get_extra_params(batch)
    pipeline_id = Ecto.UUID.generate()

    pipeline_params =
      extra
      |> Map.put("batch_id",      batch.id)
      |> Map.put("batch_item_id", item.id)
      |> Map.put("url",           item.url)

    Repo.insert!(%Pipeline{
      id:           pipeline_id,
      content_type: "podcast",
      collector:    batch.collector,
      status:       "queued",
      params:       Jason.encode!(pipeline_params)
    })

    Batches.mark_item_running(item, pipeline_id)
    Dispatcher.advance(pipeline_id)
  end

  defp send_summary(batch) do
    failed_items =
      Batches.get_batch_items(batch.id)
      |> Enum.filter(&(&1.status == "failed"))

    header =
      if batch.failed == 0 do
        "✅ <b>Batch concluído</b> — #{batch.done}/#{batch.total} episódios publicados"
      else
        "⚠️ <b>Batch concluído com erros</b> — #{batch.done} publicados, #{batch.failed} falhas (batch #{batch.id})"
      end

    failed_section =
      if failed_items == [] do
        ""
      else
        items_text =
          Enum.map_join(failed_items, "\n", fn i ->
            err = if i.error, do: " — #{String.slice(i.error, 0, 80)}", else: ""
            "• pos #{i.position}: #{i.url}#{err}"
          end)

        "\n\n<b>URLs com falha (para reprocessar):</b>\n#{items_text}"
      end

    GossipGate.send(header <> failed_section, "HTML")
  end
end
