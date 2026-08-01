defmodule Flux.Repo.Migrations.CreateDocTemplates do
  use Ecto.Migration

  def change do
    create table(:doc_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :string
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:doc_templates, [:workspace_id])
    create unique_index(:doc_templates, [:workspace_id, :name])
  end
end
