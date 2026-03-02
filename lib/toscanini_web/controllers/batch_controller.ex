defmodule ToscaniniWeb.BatchController do
  use ToscaniniWeb, :controller

  alias Toscanini.{Repo, Pipeline, Batches}
  alias Toscanini.Pipeline.Dispatcher

  def create(conn, params) do
    raw_urls = params["urls"] || ""

    urls =
      raw_urls
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))

    if urls == [] do
      conn
      |> put_status(400)
      |> json(%{error: "urls is required and must not be empty"})
    else
      collector    = params["collector"] || "pocketcasts"
      extra_params = %{"force_retranscribe" => params["force_retranscribe"] || false}

      {:ok, batch} = Batches.create_batch(urls, collector, extra_params)

      # Submeter primeiro item
      first_item  = Batches.next_pending_item(batch.id)
      pipeline_id = Ecto.UUID.generate()

      pipeline_params =
        extra_params
        |> Map.put("batch_id",      batch.id)
        |> Map.put("batch_item_id", first_item.id)
        |> Map.put("url",           first_item.url)

      Repo.insert!(%Pipeline{
        id:           pipeline_id,
        content_type: "podcast",
        collector:    collector,
        status:       "queued",
        params:       Jason.encode!(pipeline_params)
      })

      Batches.mark_item_running(first_item, pipeline_id)
      Dispatcher.advance(pipeline_id)

      conn
      |> put_status(202)
      |> json(%{
        batch_id:          batch.id,
        total:             batch.total,
        status:            batch.status,
        first_pipeline_id: pipeline_id
      })
    end
  end

  def show(conn, %{"id" => id}) do
    batch = Batches.get_batch!(id)
    items = Batches.get_batch_items(id)

    items_json =
      Enum.map(items, fn i ->
        %{
          position:     i.position,
          url:          i.url,
          status:       i.status,
          pipeline_id:  i.pipeline_id,
          error:        i.error,
          started_at:   i.started_at,
          completed_at: i.completed_at
        }
      end)

    json(conn, %{
      batch_id: batch.id,
      total:    batch.total,
      done:     batch.done,
      failed:   batch.failed,
      status:   batch.status,
      items:    items_json
    })
  end
end
