defmodule Toscanini.Pipeline do
  use Ecto.Schema
  import Ecto.Changeset
  alias Toscanini.Repo

  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}

  schema "pipelines" do
    field :content_type, :string
    field :collector,    :string
    field :status,       :string, default: "queued"
    field :current_step, :string
    field :params,       :string, default: "{}"
    field :results,      :string, default: "{}"
    field :token,        :string
    field :wait_key,     :string
    field :error,        :string
    timestamps()
  end

  def changeset(pipeline, attrs) do
    pipeline |> cast(attrs, [:content_type, :collector, :status, :current_step,
                              :params, :results, :token, :wait_key, :error])
  end

  def get_params(%__MODULE__{params: p}), do: Jason.decode!(p)
  def get_results(%__MODULE__{results: r}), do: Jason.decode!(r)

  def save_result(pipeline, step, value) do
    results = get_results(pipeline) |> Map.put(to_string(step), value)
    pipeline |> changeset(%{results: Jason.encode!(results)}) |> Repo.update!()
  end

  def fail(pipeline, reason) do
    updated = pipeline |> changeset(%{status: "failed", error: reason}) |> Repo.update!()

    # Se pertence a um batch, avançar para o próximo episódio
    params = get_params(pipeline)
    case {params["batch_id"], params["batch_item_id"]} do
      {nil, _} ->
        :ok
      {batch_id, item_id} when not is_nil(item_id) ->
        Toscanini.Workers.BatchAdvanceWorker.new(%{
          "batch_id"      => batch_id,
          "batch_item_id" => item_id,
          "result"        => "error",
          "error"         => reason
        })
        |> Oban.insert!()
    end

    updated
  end

  @doc """
  Procura pipeline com mesmo slug (em results.collect.slug) que esteja
  done ou running, excluindo o pipeline actual.
  """
  def find_duplicate_by_slug(slug, exclude_pipeline_id) do
    sql = """
    SELECT id FROM pipelines
    WHERE id != ?
      AND status IN ('done', 'running')
      AND json_valid(results)
      AND json_extract(results, '$.collect.slug') = ?
    ORDER BY inserted_at ASC
    LIMIT 1
    """

    case Repo.query(sql, [exclude_pipeline_id, slug]) do
      {:ok, %{rows: [[id]]}} -> id
      _ -> nil
    end
  end

  @doc """
  Marca pipeline como duplicado — status done, current_step done,
  com nota de duplicação nos results.
  """
  def mark_duplicate(pipeline, original_pipeline_id) do
    results = get_results(pipeline)
              |> Map.put("duplicate_of", original_pipeline_id)
              |> Map.put("skipped_reason", "duplicate_slug")

    pipeline
    |> changeset(%{
      status: "done",
      current_step: "done",
      results: Jason.encode!(results)
    })
    |> Repo.update!()

    # Se pertence a um batch, avançar para o próximo episódio
    params = get_params(pipeline)
    case {params["batch_id"], params["batch_item_id"]} do
      {nil, _} -> :ok
      {batch_id, item_id} when not is_nil(item_id) ->
        Toscanini.Workers.BatchAdvanceWorker.new(%{
          "batch_id"      => batch_id,
          "batch_item_id" => item_id,
          "result"        => "done"
        })
        |> Oban.insert!()
    end

    :ok
  end

end
