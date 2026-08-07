defmodule Flux.Repo.Migrations.CreateDatasetUrlSources do
  use Ecto.Migration

  def change do
    create table(:dataset_url_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :url, :text, null: false
      add :crawl, :boolean, default: false, null: false
      add :last_fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:dataset_url_sources, [:workspace_id])
    create unique_index(:dataset_url_sources, [:dataset_id, :url])
  end
end
