defmodule Flux.Repo.Migrations.DocumentEnabled do
  use Ecto.Migration

  def change do
    alter table(:rag_documents) do
      add :enabled, :boolean, default: true, null: false
    end
  end
end
