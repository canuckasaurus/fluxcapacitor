defmodule Flux.Repo.Migrations.CreateInterviews do
  use Ecto.Migration

  def change do
    create table(:interviews, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :string
      add :intro, :text
      add :questions, :jsonb, null: false, default: "[]"

      timestamps(type: :utc_datetime)
    end

    create index(:interviews, [:workspace_id])
    create unique_index(:interviews, [:workspace_id, :name])
  end
end
