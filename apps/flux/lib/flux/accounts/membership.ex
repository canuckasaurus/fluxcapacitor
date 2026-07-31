defmodule Flux.Accounts.Membership do
  @moduledoc """
  Joins an account to a workspace with a role (the reference platform's `TenantAccountJoin`).

  Roles mirror the reference platform exactly: `owner` > `admin` > `editor` > `normal`, with
  `dataset_operator` as a special knowledge-only role. Exactly one membership
  per account has `current: true` — the workspace the account last switched to.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner admin editor normal dataset_operator)a

  schema "memberships" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :account, Flux.Accounts.Account
    belongs_to :invited_by, Flux.Accounts.Account

    field :role, Ecto.Enum, values: @roles
    field :current, :boolean, default: false
    field :last_active_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :account_id, :role, :current, :invited_by_id, :last_active_at])
    |> validate_required([:workspace_id, :account_id, :role])
    |> unique_constraint([:workspace_id, :account_id])
    |> unique_constraint(:workspace_id, name: :memberships_single_owner_index)
  end

  @doc "Roles allowed to administer the workspace (members, settings, providers)."
  def privileged?(role), do: role in [:owner, :admin]

  @doc "Roles allowed to create and edit apps, workflows, and datasets."
  def editing?(role), do: role in [:owner, :admin, :editor]

  @doc "Roles allowed to edit datasets (includes the knowledge-only role)."
  def dataset_editing?(role), do: role in [:owner, :admin, :editor, :dataset_operator]
end
