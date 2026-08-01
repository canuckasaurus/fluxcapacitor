defmodule Flux.Repo.Migrations.CreateRagTables do
  use Ecto.Migration

  def change do
    create table(:datasets, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :description, :text
      add :embedding_plugin_id, :string, null: false
      add :embedding_model, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:datasets, [:workspace_id])

    create table(:rag_documents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :dataset_id, references(:datasets, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :error, :text
      add :segment_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_documents, [:dataset_id])

    create table(:rag_segments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :dataset_id, references(:datasets, type: :uuid, on_delete: :delete_all), null: false

      add :document_id, references(:rag_documents, type: :uuid, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :content, :text, null: false
      add :embedding, {:array, :float}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:rag_segments, [:dataset_id])
    create index(:rag_segments, [:document_id])

    execute(
      "CREATE INDEX rag_segments_content_fts ON rag_segments USING gin (to_tsvector('english', content))",
      "DROP INDEX rag_segments_content_fts"
    )
  end
end
