defmodule Flux.Repo.Migrations.CreateWorkspaceKeys do
  use Ecto.Migration

  def change do
    create table(:workspace_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dek, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_keys, [:workspace_id])
  end
end
