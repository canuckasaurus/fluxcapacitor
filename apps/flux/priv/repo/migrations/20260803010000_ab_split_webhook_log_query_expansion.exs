defmodule Flux.Repo.Migrations.AbSplitWebhookLogQueryExpansion do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :ab_version_b, :integer
      add :ab_split, :integer, null: false, default: 0
    end

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :endpoint_id, references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all)

      add :event, :string, null: false
      add :url, :string, null: false
      add :status, :integer
      add :attempts, :integer, null: false, default: 0
      add :last_error, :string
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_deliveries, [:workspace_id])
    create index(:webhook_deliveries, [:endpoint_id])

    alter table(:datasets) do
      add :query_expansion, :boolean, null: false, default: false
    end
  end
end
