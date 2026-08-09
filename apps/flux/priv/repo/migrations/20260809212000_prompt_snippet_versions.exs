defmodule Flux.Repo.Migrations.PromptSnippetVersions do
  use Ecto.Migration

  def change do
    create table(:prompt_snippet_versions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :snippet_id, references(:prompt_snippets, type: :uuid, on_delete: :delete_all),
        null: false

      add :version, :integer, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:prompt_snippet_versions, [:snippet_id])
  end
end
