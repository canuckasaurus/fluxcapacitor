defmodule Flux.Repo.Migrations.SoftDelete do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :deleted_at, :utc_datetime
    end

    alter table(:apps) do
      add :deleted_at, :utc_datetime
    end
  end
end
