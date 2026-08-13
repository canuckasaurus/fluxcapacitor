defmodule Flux.Repo.Migrations.Batch32 do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :qa_indexing, :boolean, default: false, null: false
    end

    alter table(:apps) do
      add :icon, :string
    end

    alter table(:workflow_runs) do
      add :tags, {:array, :string}, default: [], null: false
    end

    create index(:workflow_runs, [:tags], using: :gin)

    alter table(:messages) do
      add :pinned, :boolean, default: false, null: false
    end
  end
end
