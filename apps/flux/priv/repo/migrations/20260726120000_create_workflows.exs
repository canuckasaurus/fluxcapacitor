defmodule Flux.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def up do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :graph, :map, null: false, default: %{}
      add :created_by_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:workflows, [:workspace_id])

    create table(:workflow_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version, :integer, null: false
      add :graph, :map, null: false
      add :published_by_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflow_versions, [:workflow_id, :version])
    create index(:workflow_versions, [:workspace_id])

    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version, :integer
      add :status, :string, null: false, default: "running"
      add :source, :string, null: false, default: "draft"
      add :inputs, :map, null: false, default: %{}
      add :outputs, :map, null: false, default: %{}
      add :error, :text
      add :node_executions, {:array, :map}, null: false, default: []
      add :elapsed_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_runs, [:workspace_id])
    create index(:workflow_runs, [:workflow_id, :inserted_at])

    # Service tokens may now bind to a workflow ("flux-…") instead of an app.
    execute "ALTER TABLE api_tokens ALTER COLUMN app_id DROP NOT NULL"

    alter table(:api_tokens) do
      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all)
    end

    create index(:api_tokens, [:workflow_id])

    create constraint(:api_tokens, :api_tokens_binding,
             check: "(app_id IS NOT NULL) OR (workflow_id IS NOT NULL)"
           )
  end

  def down do
    drop constraint(:api_tokens, :api_tokens_binding)

    alter table(:api_tokens) do
      remove :workflow_id
    end

    execute "DELETE FROM api_tokens WHERE app_id IS NULL"
    execute "ALTER TABLE api_tokens ALTER COLUMN app_id SET NOT NULL"

    drop table(:workflow_runs)
    drop table(:workflow_versions)
    drop table(:workflows)
  end
end
