defmodule Flux.Repo.Migrations.Batch45 do
  use Ecto.Migration

  def change do
    alter table(:webhook_endpoints) do
      # Optional app binding: app-scoped events (conversation/message/
      # handoff) deliver only when they belong to this app, and
      # non-app events skip the endpoint entirely.
      add :app_id, references(:apps, type: :uuid, on_delete: :nilify_all)
    end
  end
end
