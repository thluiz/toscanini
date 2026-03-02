defmodule Toscanini.Batches do
  import Ecto.Query
  alias Toscanini.{Repo, Batch, BatchItem}

  def create_batch(urls_list, collector \\ "pocketcasts", extra_params \\ %{}) do
    id = Ecto.UUID.generate()

    batch = %Batch{
      id:          id,
      total:       length(urls_list),
      done:        0,
      failed:      0,
      status:      "running",
      collector:   collector,
      extra_params: Jason.encode!(extra_params)
    }

    {:ok, batch} = Repo.insert(batch)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    items =
      urls_list
      |> Enum.with_index()
      |> Enum.map(fn {url, idx} ->
        %{
          batch_id:    id,
          url:         url,
          position:    idx,
          status:      "pending",
          inserted_at: now,
          updated_at:  now
        }
      end)

    Repo.insert_all(BatchItem, items)

    {:ok, batch}
  end

  def get_batch!(id), do: Repo.get!(Batch, id)

  def get_batch_items(batch_id) do
    from(i in BatchItem,
      where: i.batch_id == ^batch_id,
      order_by: i.position
    )
    |> Repo.all()
  end

  def get_item!(id), do: Repo.get!(BatchItem, id)

  def get_item_by_pipeline(pipeline_id) do
    Repo.get_by(BatchItem, pipeline_id: pipeline_id)
  end

  def next_pending_item(batch_id) do
    from(i in BatchItem,
      where: i.batch_id == ^batch_id and i.status == "pending",
      order_by: i.position,
      limit: 1
    )
    |> Repo.one()
  end

  def mark_item_running(item, pipeline_id) do
    item
    |> BatchItem.changeset(%{
      status:     "running",
      pipeline_id: pipeline_id,
      started_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  def mark_item_done(item) do
    item
    |> BatchItem.changeset(%{
      status:       "done",
      completed_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    })
    |> Repo.update!()

    from(b in Batch, where: b.id == ^item.batch_id)
    |> Repo.update_all(inc: [done: 1])

    check_batch_complete(item.batch_id)
  end

  def mark_item_failed(item, error \\ nil) do
    item
    |> BatchItem.changeset(%{
      status:       "failed",
      error:        error,
      completed_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    })
    |> Repo.update!()

    from(b in Batch, where: b.id == ^item.batch_id)
    |> Repo.update_all(inc: [failed: 1])

    check_batch_complete(item.batch_id)
  end

  defp check_batch_complete(batch_id) do
    batch = get_batch!(batch_id)

    if batch.done + batch.failed >= batch.total do
      batch
      |> Batch.changeset(%{status: "done"})
      |> Repo.update!()
    end

    :ok
  end
end
