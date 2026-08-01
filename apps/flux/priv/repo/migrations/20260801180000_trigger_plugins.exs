defmodule Flux.Repo.Migrations.TriggerPlugins do
  use Ecto.Migration

  def change do
    alter table(:workflow_triggers) do
      add :plugin_id, :string
      add :plugin_cursor, :text
    end
  end
end
