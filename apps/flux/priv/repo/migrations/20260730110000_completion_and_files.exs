defmodule Flux.Repo.Migrations.CompletionAndFiles do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :prompt_template, :text
      add :input_form, {:array, :map}, null: false, default: []
    end

    create table(:uploaded_files, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :key, :string, null: false
      add :size, :integer, null: false
      add :content_type, :string
      add :end_user_ref, :string

      timestamps(type: :utc_datetime)
    end

    create index(:uploaded_files, [:workspace_id])
  end
end
