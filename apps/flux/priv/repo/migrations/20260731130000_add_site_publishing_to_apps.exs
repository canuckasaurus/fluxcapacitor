defmodule Flux.Repo.Migrations.AddSitePublishingToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :site_token, :string
      add :site_enabled, :boolean, default: false, null: false
    end

    create unique_index(:apps, [:site_token])
  end
end
