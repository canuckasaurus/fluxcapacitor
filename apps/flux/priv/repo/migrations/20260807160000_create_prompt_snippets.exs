defmodule Flux.Repo.Migrations.CreatePromptSnippets do
  use Ecto.Migration

  def change do
    create table(:prompt_snippets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:prompt_snippets, [:workspace_id])
    create unique_index(:prompt_snippets, [:workspace_id, :name])
  end
end
