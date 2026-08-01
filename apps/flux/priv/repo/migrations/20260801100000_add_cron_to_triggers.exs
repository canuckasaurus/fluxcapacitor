defmodule Flux.Repo.Migrations.AddCronToTriggers do
  use Ecto.Migration

  def change do
    alter table(:workflow_triggers) do
      add :cron, :string
    end
  end
end
