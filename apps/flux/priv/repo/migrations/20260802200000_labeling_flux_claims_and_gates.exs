defmodule Flux.Repo.Migrations.LabelingFluxClaimsAndGates do
  use Ecto.Migration

  def change do
    alter table(:labeling_tasks) do
      # A task queued by a labeling node remembers its paused run so the
      # label can resume it.
      add :run_id, references(:workflow_runs, type: :binary_id, on_delete: :nilify_all)
      add :node_id, :string
      # Soft claims keep two labelers off the same task.
      add :assigned_to_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :claimed_at, :utc_datetime
    end

    create index(:labeling_tasks, [:run_id])

    alter table(:eval_sets) do
      # Gated sets re-run automatically against every newly published version.
      add :gate, :boolean, default: false, null: false
    end
  end
end
