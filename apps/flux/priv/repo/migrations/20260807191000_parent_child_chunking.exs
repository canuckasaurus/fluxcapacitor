defmodule Flux.Repo.Migrations.ParentChildChunking do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :parent_child, :boolean, null: false, default: false
    end

    alter table(:rag_segments) do
      add :parent_content, :text
    end
  end
end
