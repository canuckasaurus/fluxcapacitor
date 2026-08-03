defmodule Flux.Repo.Migrations.MarkdownSplitRegistryNotifications do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :split_markdown, :boolean, null: false, default: false
    end

    create table(:model_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :file_id, references(:uploaded_files, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_run_id, references(:workflow_runs, type: :binary_id, on_delete: :nilify_all)

      add :name, :string, null: false
      add :version, :integer, null: false
      add :metrics, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:model_artifacts, [:workspace_id, :name, :version])

    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :title, :string, null: false
      add :path, :string
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:workspace_id, :read_at])
  end
end
