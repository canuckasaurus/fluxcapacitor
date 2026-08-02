defmodule Flux.Repo.Migrations.CreateWorkflowBatches do
  use Ecto.Migration

  def change do
    create table(:workflow_batches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string
      add :status, :string, default: "running", null: false
      add :graph, :map, null: false
      add :rows, {:array, :map}, default: [], null: false
      add :total, :integer, default: 0, null: false
      add :succeeded, :integer, default: 0, null: false
      add :failed, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_batches, [:workflow_id])
    create index(:workflow_batches, [:workspace_id])

    alter table(:workflow_runs) do
      add :batch_id, references(:workflow_batches, type: :binary_id, on_delete: :delete_all)
    end

    create index(:workflow_runs, [:batch_id])
  end
end
