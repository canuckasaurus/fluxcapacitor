defmodule Flux.Repo.Migrations.AddDocxToDocTemplates do
  use Ecto.Migration

  def change do
    alter table(:doc_templates) do
      add :kind, :string, null: false, default: "text"
      add :file_key, :string
      add :variables, {:array, :string}, null: false, default: []
    end

    execute "ALTER TABLE doc_templates ALTER COLUMN content DROP NOT NULL", ""
  end
end
