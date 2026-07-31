defmodule Flux.Repo.Migrations.AddRunSnapshot do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      # Pause snapshot for human-input resumption: pool + node + prompt.
      add :snapshot, :map
    end
  end
end
