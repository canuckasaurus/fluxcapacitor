defmodule Flux.Repo.Migrations.Batch31 do
  use Ecto.Migration

  def up do
    alter table(:datasets) do
      add :retrieval_mode, :string, default: "hybrid", null: false
      add :semantic_weight, :float
    end

    # The full-text RRF source computes to_tsvector per row per query;
    # this expression index (matching keyword_hits/4 exactly) makes it
    # an index scan.
    execute """
    CREATE INDEX IF NOT EXISTS rag_segments_content_fts
    ON rag_segments USING gin (to_tsvector('english', content))
    """

    alter table(:accounts) do
      add :totp_secret, :binary
      add :totp_confirmed_at, :utc_datetime
      add :totp_recovery_codes, {:array, :string}, default: [], null: false
    end

    alter table(:apps) do
      add :site_passcode_hash, :string
    end

    alter table(:api_tokens) do
      add :rate_limit_per_minute, :integer
    end

    create table(:run_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:run_comments, [:run_id])
    create index(:run_comments, [:workspace_id])
  end

  def down do
    drop table(:run_comments)

    alter table(:api_tokens) do
      remove :rate_limit_per_minute
    end

    alter table(:apps) do
      remove :site_passcode_hash
    end

    alter table(:accounts) do
      remove :totp_secret
      remove :totp_confirmed_at
      remove :totp_recovery_codes
    end

    execute "DROP INDEX IF EXISTS rag_segments_content_fts"

    alter table(:datasets) do
      remove :retrieval_mode
      remove :semantic_weight
    end
  end
end
