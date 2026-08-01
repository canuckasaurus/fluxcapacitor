defmodule Flux.Repo.Migrations.CredentialIsDefault do
  use Ecto.Migration

  def change do
    alter table(:provider_credentials) do
      add :is_default, :boolean, default: false, null: false
    end

    execute("UPDATE provider_credentials SET is_default = (name = 'default')", "")
  end
end
