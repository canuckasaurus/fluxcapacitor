defmodule Flux.Repo.Migrations.CreateApiToolsets do
  use Ecto.Migration

  def change do
    create table(:api_toolsets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :base_url, :string, null: false, default: ""
      add :spec, :map, null: false, default: %{}
      add :operations, {:array, :map}, null: false, default: []
      add :encrypted_auth, :text
      add :encrypted_variables, :text
      add :created_by_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:api_toolsets, [:workspace_id])
    create unique_index(:api_toolsets, [:workspace_id, :name])
  end
end
