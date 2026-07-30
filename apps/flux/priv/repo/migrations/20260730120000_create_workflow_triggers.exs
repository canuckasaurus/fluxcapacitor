defmodule Flux.Repo.Migrations.CreateWorkflowTriggers do
  use Ecto.Migration

  def change do
    create table(:workflow_triggers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :type, :string, null: false
      add :token, :string
      add :interval_minutes, :integer
      add :inputs, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflow_triggers, [:token])
    create index(:workflow_triggers, [:workspace_id])
    create index(:workflow_triggers, [:workflow_id])
  end
end
