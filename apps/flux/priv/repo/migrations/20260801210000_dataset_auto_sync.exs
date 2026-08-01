defmodule Flux.Repo.Migrations.DatasetAutoSync do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :sync_plugin_id, :string
      add :sync_interval_minutes, :integer
      add :last_synced_at, :utc_datetime
    end
  end
end
