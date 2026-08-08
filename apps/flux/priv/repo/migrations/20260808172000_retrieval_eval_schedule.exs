defmodule Flux.Repo.Migrations.RetrievalEvalSchedule do
  use Ecto.Migration

  def change do
    alter table(:datasets) do
      add :retrieval_eval_cron, :string
      add :last_retrieval_hit_rate, :float
      add :last_retrieval_mrr, :float
      add :last_retrieval_eval_at, :utc_datetime
    end
  end
end
