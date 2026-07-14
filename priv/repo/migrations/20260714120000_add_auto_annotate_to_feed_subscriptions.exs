defmodule Toscanini.Repo.Migrations.AddAutoAnnotateToFeedSubscriptions do
  use Ecto.Migration

  # Flag por-feed: quando true, o pipeline roda a etapa de anotação automática
  # (suggest-annotations → annotate) antes de publicar. Default false — só os
  # programas explicitamente marcados anotam; entrada manual não é afetada.
  def change do
    alter table(:feed_subscriptions) do
      add :auto_annotate, :boolean, null: false, default: false
    end
  end
end
