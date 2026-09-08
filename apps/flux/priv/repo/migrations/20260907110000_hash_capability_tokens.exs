defmodule Flux.Repo.Migrations.HashCapabilityTokens do
  use Ecto.Migration

  @tables [
    {:apps, :email_channel_token, :email_channel_token_hash},
    {:apps, :slack_channel_token, :slack_channel_token_hash},
    {:apps, :site_token, :site_token_hash},
    {:workflows, :site_token, :site_token_hash},
    {:conversations, :share_token, :share_token_hash},
    {:uploaded_files, :download_token, :download_token_hash}
  ]

  def up do
    for {table, _plain, hash} <- @tables do
      alter table(table) do
        add hash, :binary
      end
    end

    # Backfill in Elixir (not SQL digest()) so the hash matches exactly
    # what :crypto.hash(:sha256, ...) computes at lookup time — no
    # pgcrypto dependency, and correct regardless of encoding.
    for {table, plain, hash} <- @tables do
      rows = repo().query!("SELECT id, #{plain} FROM #{table} WHERE #{plain} IS NOT NULL")

      for [id, token] <- rows.rows do
        digest = :crypto.hash(:sha256, token)
        repo().query!("UPDATE #{table} SET #{hash} = $1 WHERE id = $2", [digest, id])
      end
    end

    for {table, _plain, hash} <- @tables do
      create unique_index(table, [hash],
               where: "#{hash} IS NOT NULL",
               name: :"#{table}_#{hash}_index"
             )
    end
  end

  def down do
    for {table, _plain, hash} <- @tables do
      drop unique_index(table, [hash], name: :"#{table}_#{hash}_index")

      alter table(table) do
        remove hash
      end
    end
  end
end
