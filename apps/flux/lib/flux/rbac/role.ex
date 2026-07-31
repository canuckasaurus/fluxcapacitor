defmodule Flux.RBAC.Role do
  @moduledoc """
  A per-workspace custom role: a named subset of the permission catalog.
  A membership pointing at one is authorized by exactly that subset,
  overriding its built-in role's grants.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Flux.RBAC.Permission

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "roles" do
    belongs_to :workspace, Flux.Accounts.Workspace

    field :name, :string
    field :permissions, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :permissions])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> update_change(:permissions, fn permissions ->
      permissions |> Enum.map(&to_string/1) |> Enum.uniq()
    end)
    |> validate_change(:permissions, fn :permissions, permissions ->
      invalid =
        Enum.reject(permissions, fn permission ->
          Enum.any?(Permission.all(), &(to_string(&1) == permission))
        end)

      if invalid == [], do: [], else: [permissions: "unknown: #{Enum.join(invalid, ", ")}"]
    end)
    |> unique_constraint([:workspace_id, :name])
  end
end
