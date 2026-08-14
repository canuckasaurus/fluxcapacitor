defmodule Flux.Accounts.Favorite do
  @moduledoc "A per-account star on a flux or app — starred float to the top."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "account_favorites" do
    belongs_to :account, Flux.Accounts.Account

    field :item_type, :string
    field :item_id, :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
