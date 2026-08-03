defmodule Flux.Repo.Migrations.RetrievalCases do
  use Ecto.Migration

  def change do
    create table(:retrieval_cases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :question, :string, null: false
      add :expected, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:retrieval_cases, [:dataset_id])
  end
end
