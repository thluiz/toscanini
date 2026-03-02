defmodule Toscanini.Repo.Migrations.CreatePipelines do
  use Ecto.Migration

  def change do
    create table(:pipelines, primary_key: false) do
      add :id,           :string, primary_key: true
      add :content_type, :string, null: false
      add :collector,    :string
      add :status,       :string, null: false, default: "queued"
      add :current_step, :string
      add :params,       :text, default: "{}"
      add :results,      :text, default: "{}"
      add :token,        :string
      add :wait_key,     :string
      add :error,        :text
      timestamps()
    end

    create unique_index(:pipelines, [:token], where: "token IS NOT NULL")
  end
end
