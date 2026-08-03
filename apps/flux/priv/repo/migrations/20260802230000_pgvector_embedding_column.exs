defmodule Flux.Repo.Migrations.PgvectorEmbeddingColumn do
  use Ecto.Migration

  # Guarded: databases without the pgvector extension (stock dev/test
  # Postgres) skip this cleanly — the Naive backend keeps working, and
  # the PgVector backend reports unavailable.
  def up do
    if vector_available?() do
      execute "CREATE EXTENSION IF NOT EXISTS vector"
      execute "ALTER TABLE rag_segments ADD COLUMN IF NOT EXISTS embedding_vec vector"
    end
  end

  def down do
    execute "ALTER TABLE rag_segments DROP COLUMN IF EXISTS embedding_vec"
  end

  defp vector_available? do
    %{rows: [[count]]} =
      repo().query!("SELECT count(*) FROM pg_available_extensions WHERE name = 'vector'")

    count > 0
  end
end
