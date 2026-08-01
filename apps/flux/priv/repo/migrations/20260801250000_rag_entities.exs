defmodule Flux.Repo.Migrations.RagEntities do
  use Ecto.Migration

  def change do
    create table(:rag_entities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:rag_entities, [:dataset_id, :name])
    create index(:rag_entities, [:workspace_id])

    create table(:rag_entity_mentions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :entity_id, references(:rag_entities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :segment_id, references(:rag_segments, type: :binary_id, on_delete: :delete_all),
        null: false
    end

    create unique_index(:rag_entity_mentions, [:entity_id, :segment_id])
    create index(:rag_entity_mentions, [:segment_id])
    create index(:rag_entity_mentions, [:dataset_id])
  end
end
