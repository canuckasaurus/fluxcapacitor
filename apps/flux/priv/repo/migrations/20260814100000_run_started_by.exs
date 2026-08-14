defmodule Flux.Repo.Migrations.RunStartedBy do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :started_by, :string
    end
  end
end
