defmodule Flux.Repo.Migrations.SegmentEnabled do
  use Ecto.Migration

  def change do
    alter table(:rag_segments) do
      add :enabled, :boolean, default: true, null: false
    end
  end
end
