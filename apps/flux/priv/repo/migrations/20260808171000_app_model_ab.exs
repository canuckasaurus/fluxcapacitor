defmodule Flux.Repo.Migrations.AppModelAb do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :ab_provider_plugin_id, :string
      add :ab_model, :string
      add :ab_split, :integer, null: false, default: 0
    end
  end
end
