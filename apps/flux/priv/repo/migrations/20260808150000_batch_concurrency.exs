defmodule Flux.Repo.Migrations.BatchConcurrency do
  use Ecto.Migration

  def change do
    alter table(:workflow_batches) do
      add :concurrency, :integer, null: false, default: 1
    end
  end
end
