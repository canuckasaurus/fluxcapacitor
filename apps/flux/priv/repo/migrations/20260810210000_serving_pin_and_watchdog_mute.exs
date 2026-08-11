defmodule Flux.Repo.Migrations.ServingPinAndWatchdogMute do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :pinned_version, :integer
    end

    alter table(:workflow_triggers) do
      add :watchdog_muted, :boolean, null: false, default: false
    end
  end
end
