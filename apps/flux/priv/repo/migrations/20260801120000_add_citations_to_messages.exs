defmodule Flux.Repo.Migrations.AddCitationsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :citations, {:array, :map}, default: [], null: false
    end
  end
end
