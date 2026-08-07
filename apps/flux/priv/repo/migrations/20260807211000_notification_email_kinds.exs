defmodule Flux.Repo.Migrations.NotificationEmailKinds do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :notification_email_kinds, {:array, :string}, null: false, default: []
    end
  end
end
