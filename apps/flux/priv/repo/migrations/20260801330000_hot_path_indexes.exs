defmodule Flux.Repo.Migrations.HotPathIndexes do
  use Ecto.Migration

  # Indexes for the listing/lookup paths that grew this cycle.
  def change do
    create_if_not_exists index(:conversations, [:app_id, :end_user_ref])
    create_if_not_exists index(:workflow_runs, [:workflow_id, :inserted_at])
    create_if_not_exists index(:audit_logs, [:workspace_id, :inserted_at])
    create_if_not_exists index(:messages, [:workspace_id, :inserted_at])
    create_if_not_exists index(:workflow_versions, [:workflow_id, :version])
  end
end
