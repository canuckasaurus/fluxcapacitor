defmodule Flux.Repo.Migrations.AddFeedbackToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :feedback, :string
    end
  end
end
