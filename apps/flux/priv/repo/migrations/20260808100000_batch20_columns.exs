defmodule Flux.Repo.Migrations.Batch20Columns do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :labels, {:array, :string}, null: false, default: []
      add :handoff_requested_at, :utc_datetime
    end

    alter table(:rag_documents) do
      add :metadata, :map, null: false, default: %{}
    end

    alter table(:webhook_endpoints) do
      add :format, :string, null: false, default: "json"
    end

    # Instance-wide key/value settings (status-page incident note).
    create table(:instance_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text

      timestamps(type: :utc_datetime)
    end
  end
end
