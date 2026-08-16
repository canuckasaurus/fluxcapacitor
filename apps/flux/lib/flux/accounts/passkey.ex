defmodule Flux.Accounts.Passkey do
  @moduledoc """
  A WebAuthn credential bound to an account: the authenticator's
  credential id, its COSE public key (raw CBOR-decoded map, stored as
  an Erlang term), and the signature counter for clone detection.
  """
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "accounts_passkeys" do
    belongs_to :account, Flux.Accounts.Account

    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :name, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
