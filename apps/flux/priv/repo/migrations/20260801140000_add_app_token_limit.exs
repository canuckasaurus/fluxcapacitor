defmodule Flux.Repo.Migrations.AddAppTokenLimit do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      # nil = unlimited; counts input+output tokens per UTC day.
      add :daily_token_limit, :bigint
    end
  end
end
