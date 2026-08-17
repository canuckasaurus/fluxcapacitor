defmodule Flux.Repo.Migrations.Batch41 do
  use Ecto.Migration

  def change do
    # Agent-only comments on a conversation — never shown to the visitor.
    create table(:conversation_notes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all),
        null: false

      add :author_email, :string
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:conversation_notes, [:conversation_id])
    create index(:conversation_notes, [:workspace_id])

    alter table(:conversations) do
      # Resolve state: set when a human marks the thread done; a fresh
      # visitor message clears it (reopen).
      add :resolved_at, :utc_datetime
      # SLA alert bookkeeping: set once the overdue-handoff warning
      # fired; reset when the visitor asks for a human again.
      add :handoff_alerted_at, :utc_datetime
    end

    alter table(:apps) do
      # Weekly schedule for the public site: %{"days" => [...],
      # "open" => h, "close" => h, "note" => "..."} (UTC hours).
      # Empty means always open.
      add :business_hours, :map, default: %{}, null: false
    end
  end
end
