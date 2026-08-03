defmodule Flux.Repo.Migrations.ConsensusVotesAndEvalSchedules do
  use Ecto.Migration

  def change do
    alter table(:labeling_projects) do
      add :required_labels, :integer, null: false, default: 1
    end

    create table(:labeling_task_votes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :task_id, references(:labeling_tasks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :label, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:labeling_task_votes, [:task_id])
    create index(:labeling_task_votes, [:workspace_id])

    alter table(:eval_sets) do
      add :schedule, :string
    end
  end
end
