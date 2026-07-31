defmodule Flux.Repo.Migrations.CreateCustomRoles do
  use Ecto.Migration

  def change do
    create table(:roles, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :permissions, {:array, :string}, default: [], null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:workspace_id, :name])

    alter table(:memberships) do
      add :custom_role_id, references(:roles, type: :uuid, on_delete: :nilify_all)
    end
  end
end
