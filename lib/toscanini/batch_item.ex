defmodule Toscanini.BatchItem do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, except: [:__meta__]}

  schema "batch_items" do
    field :batch_id,     :string
    field :url,          :string
    field :position,     :integer
    field :status,       :string, default: "pending"
    field :pipeline_id,  :string
    field :error,        :string
    field :started_at,   :naive_datetime
    field :completed_at, :naive_datetime
    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:batch_id, :url, :position, :status,
                    :pipeline_id, :error, :started_at, :completed_at])
  end
end
