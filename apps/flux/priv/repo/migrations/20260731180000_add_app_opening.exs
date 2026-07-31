defmodule Flux.Repo.Migrations.AddAppOpening do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :opening_statement, :text
      add :suggested_questions, {:array, :text}, default: [], null: false
    end
  end
end
