defmodule Flux.Repo.Migrations.DatasetLabelingTrash do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :deleted_at, :utc_datetime
    end

    alter table(:labeling_projects) do
      add :deleted_at, :utc_datetime
    end
  end
end
