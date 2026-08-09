defmodule Flux.Repo.Migrations.VersionNotes do
  use Ecto.Migration

  def change do
    alter table(:workflow_versions) do
      add :note, :string
    end
  end
end
