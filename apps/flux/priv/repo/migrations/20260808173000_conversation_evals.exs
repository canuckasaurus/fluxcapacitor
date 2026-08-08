defmodule Flux.Repo.Migrations.ConversationEvals do
  use Ecto.Migration

  def change do
    create table(:conversation_evals, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false
      add :app_id, references(:apps, type: :uuid, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :turns, {:array, :text}, null: false, default: []
      add :expectation, :text, null: false
      add :judge, :string

      add :last_score, :float
      add :last_reason, :text
      add :last_transcript, {:array, :map}, null: false, default: []
      add :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:conversation_evals, [:workspace_id])
    create index(:conversation_evals, [:app_id])
  end
end
