defmodule Flux.Repo.Migrations.DatasetSettings do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :chunk_size, :integer, default: 1000, null: false
      add :chunk_overlap, :integer, default: 120, null: false
    end

    alter table(:rag_documents) do
      # Source text is retained so re-indexing can re-chunk with new settings.
      add :content, :text
    end
  end
end
