defmodule Flux.Repo.Migrations.Batch37 do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:push_subscriptions, [:account_id, :endpoint])
  end
end
