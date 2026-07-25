defmodule Dify.RBAC do
  @moduledoc """
  Authorization checks against the caller's `Dify.Accounts.Scope`.

  Built-in workspace roles map to fixed permission sets defined here
  (mirroring Dify's legacy role semantics); per-workspace custom roles layer
  on top later via `roles`/`role_permissions` rows without changing callers.

  Usage in contexts:

      with :ok <- Dify.RBAC.authorize(scope, :app_edit) do ...

  In LiveViews via the `on_mount` hook, and in API pipelines via a plug —
  all funnel through `can?/3`.
  """

  alias Dify.Accounts.Scope
  alias Dify.RBAC.Permission

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

  defp role_grants?(role, _permission) when role in [:owner, :admin], do: true

  defp role_grants?(:editor, permission), do: MapSet.member?(@editor_permissions, permission)
  defp role_grants?(:normal, permission), do: MapSet.member?(@normal_permissions, permission)

  defp role_grants?(:dataset_operator, permission),
    do: MapSet.member?(@dataset_operator_permissions, permission)

  defp role_grants?(_role, _permission), do: false
end
