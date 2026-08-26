defmodule Flux.Repo.Migrations.Batch44 do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      # Instance-admin suspension: members see a notice, runs and API
      # refuse, data stays intact.
      add :suspended_at, :utc_datetime
    end

    alter table(:apps) do
      # Guardrail scope: "inherit" (workspace rules), "off" (skip the
      # pattern checks), or "extra" (workspace rules + the app's own).
      add :guardrails_mode, :string, default: "inherit", null: false
      add :guardrail_patterns, :text
    end

    alter table(:api_toolsets) do
      # Where a URL-imported toolset came from, so it can re-import
      # when the spec changes (auth and variables survive).
      add :source_url, :string
    end
  end
end
