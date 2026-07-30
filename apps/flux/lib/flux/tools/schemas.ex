defmodule Flux.Tools.ApiToolset do
  @moduledoc """
  An imported OpenAPI spec whose operations are callable as tools.

  `encrypted_auth` and `encrypted_variables` hold workspace-DEK envelopes
  (`Flux.Crypto`): auth is `%{"type", "in", "name", "value"}`; variables are
  a `%{name => secret}` map referenced from arguments as `{{vars.name}}`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_toolsets" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :created_by, Flux.Accounts.Account

    field :name, :string
    field :description, :string
    field :base_url, :string, default: ""
    field :spec, :map, default: %{}
    field :operations, {:array, :map}, default: []
    field :encrypted_auth, :string, redact: true
    field :encrypted_variables, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  def changeset(toolset, attrs) do
    toolset
    |> cast(attrs, [:name, :description, :base_url])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:workspace_id, :name])
  end
end
