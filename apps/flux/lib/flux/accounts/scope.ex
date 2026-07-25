defmodule Flux.Accounts.Scope do
  @moduledoc """
  The caller's identity and authorization context, threaded as the first
  argument through every context function.

  Carries the authenticated account plus the active workspace and the
  caller's membership role in it. Query scoping (`Flux.Repo.scoped/2`) and
  RBAC checks (`Flux.RBAC.can?/3`) both read from this struct, so a function
  that receives a scope needs no other tenancy input.
  """

  alias Flux.Accounts.{Account, Membership, Workspace}

  defstruct account: nil, workspace: nil, membership: nil

  @type t :: %__MODULE__{
          account: Account.t() | nil,
          workspace: Workspace.t() | nil,
          membership: Membership.t() | nil
        }

  @doc """
  Creates a scope for the given account.

  Returns nil if no account is given.
  """
  def for_account(%Account{} = account) do
    %__MODULE__{account: account}
  end

  def for_account(nil), do: nil

  @doc "Attaches the active workspace and the account's membership in it."
  def put_workspace(%__MODULE__{} = scope, %Workspace{} = workspace, %Membership{} = membership)
      when membership.workspace_id == workspace.id do
    %{scope | workspace: workspace, membership: membership}
  end

  def workspace_id(%__MODULE__{workspace: %Workspace{id: id}}), do: id
  def workspace_id(%__MODULE__{}), do: nil

  def account_id(%__MODULE__{account: %Account{id: id}}), do: id
  def account_id(%__MODULE__{}), do: nil

  def role(%__MODULE__{membership: %Membership{role: role}}), do: role
  def role(%__MODULE__{}), do: nil
end
