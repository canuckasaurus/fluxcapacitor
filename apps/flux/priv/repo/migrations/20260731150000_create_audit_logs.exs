defmodule Flux.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all)
      add :actor_id, references(:accounts, type: :uuid, on_delete: :nilify_all)
      add :action, :string, null: false
      add :resource_type, :string
      add :resource_id, :string
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_logs, [:workspace_id, :inserted_at])
    create index(:audit_logs, [:workspace_id, :action])
  end
end
