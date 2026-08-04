defmodule Flux.Repo.Migrations.WorkspaceTemplatesDocumentTags do
  use Ecto.Migration

  def change do
    create table(:workflow_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :string
      add :graph, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_templates, [:workspace_id])

    alter table(:rag_documents) do
      add :tags, {:array, :string}, null: false, default: []
    end
  end
end
