defmodule Flux.Repo.Migrations.ConversationTrash do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :deleted_at, :utc_datetime
    end

    create index(:conversations, [:deleted_at])
  end
end
