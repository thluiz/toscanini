defmodule Toscanini.FeedSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}

  schema "feed_subscriptions" do
    field :source,            :string, default: "pocketcasts"
    field :feed_ref,          :string
    field :title,             :string
    field :active,            :boolean, default: true
    # JSON array serializado, ex.: ["thu","fri"]. nil/"[]" → janela quente sempre ligada.
    field :check_days,        :string
    field :hot_interval_min,  :integer, default: 60
    field :idle_interval_min, :integer, default: 1440
    field :last_published_at, :utc_datetime
    field :last_episode_uuid, :string
    field :last_checked_at,   :utc_datetime
    field :etag,              :string
    field :last_modified,     :string
    timestamps()
  end

  @castable ~w(source feed_ref title active check_days hot_interval_min
               idle_interval_min last_published_at last_episode_uuid
               last_checked_at etag last_modified)a

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, @castable)
    |> validate_required([:source, :feed_ref])
    |> validate_inclusion(:source, ["pocketcasts", "rss"])
    |> unique_constraint([:source, :feed_ref], name: :feed_subscriptions_source_feed_ref_index)
  end

  @doc "Lista de dias (strings lowercase, ex.: \"thu\") ou [] se não configurado."
  def check_days(%__MODULE__{check_days: nil}), do: []
  def check_days(%__MODULE__{check_days: ""}), do: []

  def check_days(%__MODULE__{check_days: raw}) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) -> Enum.map(list, &String.downcase(to_string(&1)))
      _ -> []
    end
  end
end
