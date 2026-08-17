defmodule Flux.Repo.Migrations.Batch40 do
  use Ecto.Migration

  def change do
    # External knowledge: a dataset whose retrieval is served by a
    # user-hosted HTTP endpoint instead of the local index. The API key
    # is encrypted with the workspace DEK before it lands here.
    alter table(:datasets) do
      add :external_endpoint, :string
      add :external_knowledge_id, :string
      add :external_api_key, :text
    end

    # External datasets embed nothing, so the embedding columns go
    # nullable (locally-indexed datasets still validate them in the
    # changeset).
    execute(
      "ALTER TABLE datasets ALTER COLUMN embedding_plugin_id DROP NOT NULL",
      "ALTER TABLE datasets ALTER COLUMN embedding_plugin_id SET NOT NULL"
    )

    execute(
      "ALTER TABLE datasets ALTER COLUMN embedding_model DROP NOT NULL",
      "ALTER TABLE datasets ALTER COLUMN embedding_model SET NOT NULL"
    )

    # Credential load balancing: keys flagged into the pool share the
    # traffic round-robin (and take over from each other on 429/5xx).
    alter table(:provider_credentials) do
      add :balanced, :boolean, default: false, null: false
    end

    alter table(:apps) do
      # Embed lockdown: origins allowed to iframe the published site
      # (newline/space separated). Blank keeps the embed-anywhere default.
      add :embed_origins, :text
      # Budget alerts: highest threshold already notified per month,
      # e.g. %{"2026-08" => 80} — keeps the warning to once per level.
      add :budget_alerts, :map, default: %{}, null: false
    end
  end
end
