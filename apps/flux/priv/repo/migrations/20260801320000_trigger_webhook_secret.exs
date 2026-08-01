defmodule Flux.Repo.Migrations.TriggerWebhookSecret do
  use Ecto.Migration

  def change do
    alter table(:workflow_triggers) do
      add :webhook_secret, :string
    end
  end
end
