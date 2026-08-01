defmodule Flux.Repo.Migrations.InstallationEndpointTokens do
  use Ecto.Migration

  def change do
    alter table(:plugin_installations) do
      add :endpoint_token, :string
    end

    create unique_index(:plugin_installations, [:endpoint_token])

    # Backfill existing installations so their endpoints work without a
    # reinstall (md5-of-random is fine — tokens only need to be unguessable).
    execute(
      "UPDATE plugin_installations SET endpoint_token = 'ep_' || md5(random()::text || id::text) WHERE endpoint_token IS NULL",
      ""
    )
  end
end
