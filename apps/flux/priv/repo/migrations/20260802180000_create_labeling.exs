defmodule Flux.Repo.Migrations.CreateLabeling do
  use Ecto.Migration

  def change do
    create table(:labeling_projects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :label_type, :string, default: "choice", null: false
      add :options, {:array, :string}, default: [], null: false
      add :instructions, :text

      timestamps(type: :utc_datetime)
    end

    create index(:labeling_projects, [:workspace_id])

    create table(:labeling_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id,
          references(:labeling_projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :data, :map, default: %{}, null: false
      add :status, :string, default: "unlabeled", null: false
      add :label, :map
      add :labeled_by_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :source, :string

      timestamps(type: :utc_datetime)
    end

    create index(:labeling_tasks, [:project_id, :status])
    create index(:labeling_tasks, [:workspace_id])
  end
end
