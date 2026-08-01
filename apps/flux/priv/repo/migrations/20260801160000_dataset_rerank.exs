defmodule Flux.Repo.Migrations.DatasetRerank do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :rerank_plugin_id, :string
      add :rerank_model, :string
    end
  end
end
