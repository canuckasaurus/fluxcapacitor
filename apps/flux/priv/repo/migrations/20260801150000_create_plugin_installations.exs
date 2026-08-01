defmodule Flux.Repo.Migrations.CreatePluginInstallations do
  use Ecto.Migration

  def change do
    create table(:plugin_installations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :plugin_id, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:plugin_installations, [:workspace_id, :plugin_id])
  end
end
