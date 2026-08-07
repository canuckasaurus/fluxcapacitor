defmodule Flux.Repo.Migrations.BudgetsAndRateLimits do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :monthly_token_budget, :integer
      add :budget_warned_month, :string
    end

    alter table(:apps) do
      add :rate_limit_per_minute, :integer
    end
  end
end
