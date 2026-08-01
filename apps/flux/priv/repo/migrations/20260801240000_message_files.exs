defmodule Flux.Repo.Migrations.MessageFiles do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :files, {:array, :map}, default: [], null: false
    end
  end
end
