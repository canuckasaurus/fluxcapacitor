defmodule Flux.Repo.Migrations.Batch42 do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # CSAT: the visitor's 1-5 rating and optional comment.
      add :csat_score, :integer
      add :csat_comment, :text
      # Read-only public transcript link; nil = not shared.
      add :share_token, :string
    end

    create unique_index(:conversations, [:share_token])

    alter table(:messages) do
      # Read receipt: when the visitor's open tab saw this human reply.
      add :seen_at, :utc_datetime
    end

    alter table(:memberships) do
      # Support-desk availability: round-robin handoff routing only
      # considers available members.
      add :available, :boolean, default: true, null: false
    end

    alter table(:apps) do
      # Slack channel: inbound events webhook token (slch_...) and the
      # bot token replies post with (DEK-encrypted).
      add :slack_channel_token, :string
      add :slack_bot_token, :text
    end

    create unique_index(:apps, [:slack_channel_token])

    alter table(:webhook_endpoints) do
      # Auto-disable bookkeeping: failed delivery attempts since the
      # last success; a threshold flips enabled off with a notification.
      add :consecutive_failures, :integer, default: 0, null: false
    end

    alter table(:rag_segments) do
      # Retrieval feedback: flagged from a bad citation in the monitor,
      # queued on the knowledge page for curation.
      add :flagged_at, :utc_datetime
      add :flag_note, :string
    end
  end
end
