defmodule Flux.Repo.Migrations.AddSitePublishingToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :site_token, :string
      add :site_enabled, :boolean, default: false, null: false
    end

    create unique_index(:workflows, [:site_token])
  end
end
