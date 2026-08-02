defmodule Flux.Repo.Migrations.CreateWebhookEndpoints do
  use Ecto.Migration

  def change do
    create table(:webhook_endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :url, :string, null: false
      add :secret, :string, null: false
      add :events, {:array, :string}, default: [], null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_endpoints, [:workspace_id])
  end
end
