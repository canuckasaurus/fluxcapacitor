defmodule Flux.Repo.Migrations.DatasetRetrievalSettings do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :retrieval_top_k, :integer
      add :score_threshold, :float
    end
  end
end
