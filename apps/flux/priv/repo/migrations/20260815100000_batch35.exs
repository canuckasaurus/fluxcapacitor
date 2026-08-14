defmodule Flux.Repo.Migrations.Batch35 do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :collect_visitor_info, :boolean, default: false, null: false
    end

    alter table(:conversations) do
      add :visitor_name, :string
      add :visitor_email, :string
      add :assigned_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:workflows) do
      add :publish_at, :utc_datetime
    end

    alter table(:rag_documents) do
      add :expires_at, :utc_datetime
    end
  end
end
