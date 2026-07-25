defmodule Dify.Repo.Migrations.CreateWorkspacesAndMemberships do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, null: false, default: "normal"
      add :custom_config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false
      add :current, :boolean, null: false, default: false
      add :invited_by_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :last_active_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:workspace_id, :account_id])
    create index(:memberships, [:account_id])
    create index(:memberships, [:workspace_id, :role])

    # At most one owner row per workspace is enforced at the context level;
    # this partial index guarantees it at the database level too.
    create unique_index(:memberships, [:workspace_id],
             where: "role = 'owner'",
             name: :memberships_single_owner_index
           )

    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :email, :citext, null: false
      add :role, :string, null: false
      add :token_hash, :binary, null: false
      add :invited_by_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token_hash])
    create index(:invitations, [:workspace_id])

    create unique_index(:invitations, [:workspace_id, :email],
             where: "accepted_at IS NULL",
             name: :invitations_pending_unique_index
           )
  end
end
