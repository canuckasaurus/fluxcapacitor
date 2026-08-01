defmodule Flux.Repo.Migrations.AnnotationEmbeddings do
  use Ecto.Migration

  def change do
    alter table(:annotations) do
      add :embedding, {:array, :float}
      add :embedding_plugin_id, :string
      add :embedding_model, :string
    end

    alter table(:apps) do
      add :annotation_threshold, :float
    end
  end
end
