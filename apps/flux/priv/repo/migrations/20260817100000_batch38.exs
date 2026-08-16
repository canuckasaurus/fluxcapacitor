defmodule Flux.Repo.Migrations.Batch38 do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :tags, {:array, :string}, default: [], null: false
    end

    alter table(:apps) do
      add :tags, {:array, :string}, default: [], null: false
    end

    alter table(:uploaded_files) do
      add :extracted_text, :text
    end

    alter table(:api_tokens) do
      add :dataset_id, :binary_id
    end

    alter table(:accounts_tokens) do
      add :last_used_at, :utc_datetime
    end
  end
end
