defmodule Flux.Repo.Migrations.DatasetEntityModel do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :entity_plugin_id, :string
      add :entity_model, :string
    end
  end
end
