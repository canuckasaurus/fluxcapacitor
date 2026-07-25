defmodule Dify.Accounts.Workspace do
  @moduledoc """
  A workspace (Dify's "tenant") — the unit of team collaboration and
  resource ownership. Every tenant-owned row in the system carries a
  `workspace_id` foreign key back to this table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(normal archived)

  schema "workspaces" do
    field :name, :string
    field :status, :string, default: "normal"
    field :custom_config, :map, default: %{}

    has_many :memberships, Dify.Accounts.Membership

    timestamps(type: :utc_datetime)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :status, :custom_config])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end
end
