defmodule Flux.Repo.Migrations.CreateMcpServers do
  use Ecto.Migration

  def change do
    create table(:mcp_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :url, :string, null: false
      add :encrypted_headers, :text
      add :tools, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:mcp_servers, [:workspace_id])
    create unique_index(:mcp_servers, [:workspace_id, :name])
  end
end
