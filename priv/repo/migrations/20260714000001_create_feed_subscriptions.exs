defmodule Toscanini.Repo.Migrations.CreateFeedSubscriptions do
  use Ecto.Migration

  def change do
    create table(:feed_subscriptions, primary_key: false) do
      add :id,                :string,  primary_key: true
      add :source,            :string,  null: false, default: "pocketcasts"
      add :feed_ref,          :string,  null: false
      add :title,             :string
      add :active,            :boolean, null: false, default: true
      # Dias de publicação conhecidos (janela quente). JSON array tipo ["thu"];
      # null/[] → janela quente sempre ligada (checa a cada hot_interval_min).
      add :check_days,        :text
      add :hot_interval_min,  :integer, null: false, default: 60
      add :idle_interval_min, :integer, null: false, default: 1440
      # Watermark: só processa episódios publicados depois disto (backfill off).
      add :last_published_at, :utc_datetime
      add :last_episode_uuid, :string
      add :last_checked_at,   :utc_datetime
      add :etag,              :string
      add :last_modified,     :string
      timestamps()
    end

    create index(:feed_subscriptions, [:active])
    create unique_index(:feed_subscriptions, [:source, :feed_ref])
  end
end
