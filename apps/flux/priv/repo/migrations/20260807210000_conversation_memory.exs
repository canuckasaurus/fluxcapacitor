defmodule Flux.Repo.Migrations.ConversationMemory do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :summary, :text
      add :summarized_seq, :integer
    end
  end
end
