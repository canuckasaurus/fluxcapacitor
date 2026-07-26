defmodule Flux.Providers.ProviderCredential do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "provider_credentials" do
    belongs_to :workspace, Flux.Accounts.Workspace
    field :plugin_id, :string
    field :name, :string, default: "default"
    field :encrypted_config, :string, redact: true
    field :validated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:workspace_id, :plugin_id, :name, :encrypted_config, :validated_at])
    |> validate_required([:workspace_id, :plugin_id, :encrypted_config])
    |> unique_constraint([:workspace_id, :plugin_id, :name])
  end
end
