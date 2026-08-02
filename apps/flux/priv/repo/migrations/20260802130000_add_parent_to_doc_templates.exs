defmodule Flux.Repo.Migrations.AddParentToDocTemplates do
  use Ecto.Migration

  def change do
    alter table(:doc_templates) do
      add :parent_id, references(:doc_templates, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:doc_templates, [:parent_id])
  end
end
