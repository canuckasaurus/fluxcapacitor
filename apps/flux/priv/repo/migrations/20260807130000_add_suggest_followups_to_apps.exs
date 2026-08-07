defmodule Flux.Repo.Migrations.AddSuggestFollowupsToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :suggest_followups, :boolean, default: false, null: false
    end
  end
end
