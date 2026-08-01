defmodule Flux.RBAC do
  @moduledoc """
  Authorization checks against the caller's `Flux.Accounts.Scope`.

  Built-in workspace roles map to fixed permission sets defined here
  (mirroring the reference platform's legacy role semantics); per-workspace custom roles layer
  on top later via `roles`/`role_permissions` rows without changing callers.

  Usage in contexts:

      with :ok <- Flux.RBAC.authorize(scope, :app_edit) do ...

  In LiveViews via the `on_mount` hook, and in API pipelines via a plug —
  all funnel through `can?/3`.
  """

  alias Flux.Accounts.Scope
  alias Flux.RBAC.Permission

  @editor_permissions MapSet.new(
                        Permission.app_scope() ++
                          Permission.dataset_scope() ++
                          ~w(snippets_create_and_modify credential_use)a
                      )

  @normal_permissions MapSet.new(~w(app_view_layout app_preview dataset_preview dataset_readonly
                           dataset_use credential_use)a)

  @dataset_operator_permissions MapSet.new(Permission.dataset_scope() ++ ~w(credential_use)a)

  @doc """
  Whether the scope's role grants the permission. Owners and admins hold
  every permission; other built-in roles hold the subsets below.

  Returns false for scopes without a workspace or with unknown permissions.
  """
  @spec can?(Scope.t() | nil, Permission.t(), term()) :: boolean()
  def can?(scope, permission, resource \\ nil)

  def can?(%Scope{membership: nil}, _permission, _resource), do: false
  def can?(nil, _permission, _resource), do: false

  # A membership bound to a custom role is authorized by exactly that
  # role's permission subset (built-in role grants do not apply).
  def can?(
        %Scope{membership: %{custom_role: %Flux.RBAC.Role{permissions: permissions}}},
        permission,
        _resource
      ) do
    Permission.valid?(permission) and to_string(permission) in permissions
  end

  def can?(%Scope{} = scope, permission, _resource) do
    Permission.valid?(permission) and role_grants?(Scope.role(scope), permission)
  end

  @doc "Like `can?/3` but returns `:ok | {:error, :unauthorized}` for `with` chains."
  @spec authorize(Scope.t() | nil, Permission.t(), term()) :: :ok | {:error, :unauthorized}
  def authorize(scope, permission, resource \\ nil) do
    if can?(scope, permission, resource), do: :ok, else: {:error, :unauthorized}
  end

  @doc "The full permission set for a built-in role (used by the roles UI)."
  @spec permissions_for_role(atom()) :: MapSet.t()
  def permissions_for_role(role) when role in [:owner, :admin], do: MapSet.new(Permission.all())
  def permissions_for_role(:editor), do: @editor_permissions
  def permissions_for_role(:normal), do: @normal_permissions
  def permissions_for_role(:dataset_operator), do: @dataset_operator_permissions
  def permissions_for_role(_role), do: MapSet.new()

  ## Custom roles (per-workspace named permission subsets)

  import Ecto.Query, only: [from: 2]

  alias Flux.Repo
  alias Flux.RBAC.Role

  def list_roles(%Scope{} = scope) do
    workspace_id = Scope.workspace_id(scope)
    Repo.all(from r in Role, where: r.workspace_id == ^workspace_id, order_by: r.name)
  end

  def create_role(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, :workspace_role_manage),
         {:ok, role} <-
           %Role{workspace_id: Scope.workspace_id(scope)}
           |> Role.changeset(attrs)
           |> Repo.insert() do
      Flux.Audit.record(scope, "role.create",
        resource: role,
        metadata: %{"name" => role.name, "permissions" => length(role.permissions)}
      )

      {:ok, role}
    end
  end

  def update_role(%Scope{} = scope, role_id, attrs) do
    with :ok <- authorize(scope, :workspace_role_manage),
         %Role{} = role <- get_role(scope, role_id),
         {:ok, updated} <- role |> Role.changeset(attrs) |> Repo.update() do
      Flux.Audit.record(scope, "role.update", resource: role, metadata: %{"name" => updated.name})
      {:ok, updated}
    end
  end

  def delete_role(%Scope{} = scope, role_id) do
    with :ok <- authorize(scope, :workspace_role_manage),
         %Role{} = role <- get_role(scope, role_id),
         # Memberships pointing at it fall back to their built-in role
         # (custom_role_id nilifies on delete).
         {:ok, deleted} <- Repo.delete(role) do
      Flux.Audit.record(scope, "role.delete", resource: role, metadata: %{"name" => role.name})
      {:ok, deleted}
    end
  end

  @doc "Binds (or with nil, unbinds) a membership to a custom role."
  def assign_custom_role(%Scope{} = scope, %Flux.Accounts.Membership{} = membership, role_id) do
    workspace_id = Scope.workspace_id(scope)

    with :ok <- authorize(scope, :workspace_role_manage),
         true <- membership.workspace_id == workspace_id || {:error, :not_found},
         true <- membership.role != :owner || {:error, :cannot_change_owner_role},
         :ok <- validate_role_binding(scope, role_id),
         {:ok, updated} <-
           membership |> Ecto.Changeset.change(custom_role_id: role_id) |> Repo.update() do
      Flux.Audit.record(scope, "role.assign",
        resource_type: "membership",
        resource_id: membership.id,
        metadata: %{"custom_role_id" => role_id}
      )

      {:ok, updated}
    end
  end

  defp validate_role_binding(_scope, nil), do: :ok

  defp validate_role_binding(scope, role_id) do
    case get_role(scope, role_id) do
      %Role{} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp get_role(scope, role_id) do
    workspace_id = Scope.workspace_id(scope)

    Repo.one(from r in Role, where: r.id == ^role_id and r.workspace_id == ^workspace_id) ||
      {:error, :not_found}
  end

  defp role_grants?(role, _permission) when role in [:owner, :admin], do: true

  defp role_grants?(:editor, permission), do: MapSet.member?(@editor_permissions, permission)
  defp role_grants?(:normal, permission), do: MapSet.member?(@normal_permissions, permission)

  defp role_grants?(:dataset_operator, permission),
    do: MapSet.member?(@dataset_operator_permissions, permission)

  defp role_grants?(_role, _permission), do: false
end
