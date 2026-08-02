defmodule Flux.Repo.Migrations.CreateEvals do
  use Ecto.Migration

  def change do
    create table(:eval_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:eval_sets, [:workflow_id])
    create index(:eval_sets, [:workspace_id])

    create table(:eval_cases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :eval_set_id, references(:eval_sets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :inputs, :map, default: %{}, null: false
      add :expected, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:eval_cases, [:eval_set_id])
    create index(:eval_cases, [:workspace_id])

    create table(:eval_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :eval_set_id, references(:eval_sets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target, :string, null: false
      add :grader, :string, null: false
      add :status, :string, default: "running", null: false
      add :graph, :map, null: false
      add :total, :integer, default: 0, null: false
      add :passed, :integer, default: 0, null: false
      add :failed, :integer, default: 0, null: false
      add :avg_score, :float
      add :results, {:array, :map}, default: [], null: false

      timestamps(type: :utc_datetime)
    end

    create index(:eval_runs, [:eval_set_id])
    create index(:eval_runs, [:workflow_id])
    create index(:eval_runs, [:workspace_id])
  end
end
