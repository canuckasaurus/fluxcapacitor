defmodule Flux.Repo.Migrations.CreateAnnotations do
  use Ecto.Migration

  def change do
    create table(:annotations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false

      add :question, :text, null: false
      add :answer, :text, null: false
      add :enabled, :boolean, default: true, null: false
      add :hit_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:annotations, [:app_id])
    create index(:annotations, [:workspace_id])
  end
end
