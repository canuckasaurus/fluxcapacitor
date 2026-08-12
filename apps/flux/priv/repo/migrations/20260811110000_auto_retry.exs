defmodule Flux.Repo.Migrations.AutoRetry do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :auto_retry, :boolean, null: false, default: false
    end

    alter table(:workflow_runs) do
      add :retry_of_id, references(:workflow_runs, type: :uuid, on_delete: :nilify_all)
    end
  end
end
