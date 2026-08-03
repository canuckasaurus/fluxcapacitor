defmodule Flux.Repo.Migrations.GoldLabelsBatchSchedulesCaseWeights do
  use Ecto.Migration

  def change do
    alter table(:labeling_tasks) do
      add :gold_label, :map
    end

    create table(:batch_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :rows, {:array, :map}, null: false, default: []
      add :cron, :string, null: false
      add :target, :string, null: false, default: "draft"
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:batch_schedules, [:workspace_id])
    create index(:batch_schedules, [:workflow_id])

    alter table(:eval_cases) do
      add :weight, :float, null: false, default: 1.0
    end
  end
end
