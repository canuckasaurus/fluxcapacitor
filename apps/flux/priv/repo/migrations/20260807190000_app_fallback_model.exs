defmodule Flux.Repo.Migrations.AppFallbackModel do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :fallback_provider_plugin_id, :string
      add :fallback_model, :string
    end
  end
end
