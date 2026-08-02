defmodule Flux.Repo.Migrations.AddUsageToWorkflowRuns do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :usage, :map, default: %{}, null: false
    end
  end
end
