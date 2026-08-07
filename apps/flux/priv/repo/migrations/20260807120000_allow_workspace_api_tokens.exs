defmodule Flux.Repo.Migrations.AllowWorkspaceApiTokens do
  use Ecto.Migration

  # `ws-` tokens bind to the workspace alone — the old check demanded an
  # app or flux binding, which now only applies to `app-`/`flux-` kinds.
  def up do
    drop constraint(:api_tokens, :api_tokens_binding)
  end

  def down do
    execute "DELETE FROM api_tokens WHERE app_id IS NULL AND workflow_id IS NULL"

    create constraint(:api_tokens, :api_tokens_binding,
             check: "(app_id IS NOT NULL) OR (workflow_id IS NOT NULL)"
           )
  end
end
