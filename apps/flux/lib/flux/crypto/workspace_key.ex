defmodule Flux.Crypto.WorkspaceKey do
  @moduledoc """
  A workspace's data-encryption key, stored wrapped by the master vault.
  """
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_keys" do
    belongs_to :workspace, Flux.Accounts.Workspace
    field :dek, Flux.Encrypted.Binary, redact: true

    timestamps(type: :utc_datetime)
  end
end
