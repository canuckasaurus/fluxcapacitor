defmodule Flux.Repo.Migrations.Hardening72Races do
  use Ecto.Migration

  def up do
    # Idempotency reservations are inserted *before* the work runs (so a
    # concurrent duplicate first-request can be refused instead of
    # racing the lookup); the response columns are unknown at that
    # point.
    alter table(:idempotency_keys) do
      modify :response_status, :integer, null: true
      modify :response_body, :text, null: true
    end

    # One thread per correspondent on the channels that document that
    # guarantee (email/slack inbound) — dedupe any rows a prior race
    # already created before the constraint goes on, keeping the most
    # recent conversation per (app, ref) and soft-deleting the rest.
    execute """
    UPDATE conversations c
    SET deleted_at = now()
    WHERE c.deleted_at IS NULL
      AND (c.end_user_ref LIKE 'email:%' OR c.end_user_ref LIKE 'slack:%')
      AND EXISTS (
        SELECT 1 FROM conversations newer
        WHERE newer.app_id = c.app_id
          AND newer.end_user_ref = c.end_user_ref
          AND newer.deleted_at IS NULL
          AND newer.id > c.id
      )
    """

    create unique_index(
             :conversations,
             [:app_id, :end_user_ref],
             where:
               "deleted_at IS NULL AND (end_user_ref LIKE 'email:%' OR end_user_ref LIKE 'slack:%')",
             name: :conversations_channel_thread_index
           )
  end

  def down do
    drop unique_index(:conversations, [:app_id, :end_user_ref],
           name: :conversations_channel_thread_index
         )

    alter table(:idempotency_keys) do
      modify :response_status, :integer, null: false
      modify :response_body, :text, null: false
    end
  end
end
