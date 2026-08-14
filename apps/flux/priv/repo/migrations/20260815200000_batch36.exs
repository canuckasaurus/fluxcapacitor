defmodule Flux.Repo.Migrations.Batch36 do
  use Ecto.Migration

  def change do
    create table(:app_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:app_snapshots, [:app_id])

    create table(:rag_document_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:rag_document_revisions, [:dataset_id, :name])

    create table(:account_favorites, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :item_type, :string, null: false
      add :item_id, :binary_id, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:account_favorites, [:account_id, :item_type, :item_id])

    alter table(:accounts) do
      add :quiet_hours_start, :integer
      add :quiet_hours_end, :integer
    end

    alter table(:apps) do
      add :prompt_b, :text
      add :prompt_split, :integer, default: 0, null: false
      add :fallbacks, {:array, :map}, default: [], null: false
    end

    alter table(:datasets) do
      add :embedded_tokens, :bigint, default: 0, null: false
    end

    alter table(:conversations) do
      add :handoff_first_reply_seconds, :integer
    end
  end
end
