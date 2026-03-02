defmodule Toscanini.Repo.Migrations.CreateBatches do
  use Ecto.Migration

  def change do
    create table(:batches, primary_key: false) do
      add :id,           :string,  primary_key: true
      add :total,        :integer, null: false
      add :done,         :integer, default: 0
      add :failed,       :integer, default: 0
      add :status,       :string,  default: "running"
      add :collector,    :string,  default: "pocketcasts"
      add :extra_params, :text,    default: "{}"
      timestamps()
    end

    create table(:batch_items) do
      add :batch_id,     :string,  null: false
      add :url,          :text,    null: false
      add :position,     :integer, null: false
      add :status,       :string,  default: "pending"
      add :pipeline_id,  :string
      add :error,        :text
      add :started_at,   :naive_datetime
      add :completed_at, :naive_datetime
      timestamps()
    end

    create index(:batch_items, [:batch_id])
    create index(:batch_items, [:pipeline_id])
  end
end
