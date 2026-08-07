defmodule Flux.Repo.Migrations.AddExpiresAtToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      # NULL = perpetual; a timestamp makes the token self-destruct.
      add :expires_at, :utc_datetime
    end
  end
end
