defmodule Flux.Repo.Migrations.WorkspaceEnvVars do
  use Ecto.Migration

  def change do
    create table(:workspace_env_vars, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :encrypted_value, :binary, null: false
      add :is_secret, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_env_vars, [:workspace_id, :name])
  end
end
