defmodule Flux.Repo.Migrations.SessionDeviceInfo do
  use Ecto.Migration

  def change do
    alter table(:accounts_tokens) do
      add :ip, :string
      add :user_agent, :string
    end
  end
end
