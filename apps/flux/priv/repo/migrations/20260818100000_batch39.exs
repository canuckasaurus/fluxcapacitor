defmodule Flux.Repo.Migrations.Batch39 do
  use Ecto.Migration

  def change do
    create table(:accounts_passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :name, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:accounts_passkeys, [:credential_id])
    create index(:accounts_passkeys, [:account_id])

    create table(:idempotency_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :response_status, :integer, null: false
      add :response_body, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:idempotency_keys, [:workspace_id, :key])

    alter table(:apps) do
      add :email_channel_token, :string
      add :monthly_cost_budget, :float
    end

    create unique_index(:apps, [:email_channel_token])
  end
end
