defmodule Flux.Repo.Migrations.BatchTargetsAndEvalJudges do
  use Ecto.Migration

  def change do
    alter table(:workflow_batches) do
      add :target, :string, default: "draft", null: false
    end

    alter table(:eval_runs) do
      add :judge, :string
    end
  end
end
