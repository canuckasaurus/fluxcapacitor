defmodule Flux.Repo.Migrations.ConversationEvalSchedule do
  use Ecto.Migration

  def change do
    alter table(:conversation_evals) do
      add :schedule, :string
    end
  end
end
