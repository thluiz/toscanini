defmodule Toscanini.Batch do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}

  schema "batches" do
    field :total,        :integer
    field :done,         :integer, default: 0
    field :failed,       :integer, default: 0
    field :status,       :string,  default: "running"
    field :collector,    :string,  default: "pocketcasts"
    field :extra_params, :string,  default: "{}"
    timestamps()
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [:total, :done, :failed, :status, :collector, :extra_params])
  end

  def get_extra_params(%__MODULE__{extra_params: p}), do: Jason.decode!(p)
end
