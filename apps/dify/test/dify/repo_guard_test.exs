defmodule Dify.RepoGuardTest do
  use Dify.DataCase, async: true

  import Dify.AccountsFixtures

  alias Dify.Accounts
  alias Dify.Accounts.{Invitation, Scope}
  alias Dify.Repo.UnscopedQueryError

  setup do
    account = account_fixture()
    {:ok, {_workspace, _membership}} = Accounts.create_workspace(account, %{name: "Guarded"})
    %{scope: Accounts.scope_for(account)}
  end

  test "unscoped read of a tenant table raises", _ctx do
    assert_raise UnscopedQueryError, fn -> Repo.all(Invitation) end
  end

  test "unscoped get raises", %{scope: scope} do
    {:ok, {invitation, _token}} =
      Accounts.create_invitation(scope, %{email: "g@example.com", role: :normal})

    assert_raise UnscopedQueryError, fn -> Repo.get(Invitation, invitation.id) end
  end

  test "scoped/2 query passes and filters to the workspace", %{scope: scope} do
    {:ok, {invitation, _token}} =
      Accounts.create_invitation(scope, %{email: "s@example.com", role: :normal})

    other_account = account_fixture()
    {:ok, _} = Accounts.create_workspace(other_account, %{name: "Other"})
    other_scope = Accounts.scope_for(other_account)

    {:ok, _} = Accounts.create_invitation(other_scope, %{email: "o@example.com", role: :normal})

    assert [returned] = Repo.all(Repo.scoped(Invitation, scope))
    assert returned.id == invitation.id
  end

  test "explicit workspace_id filter passes", %{scope: scope} do
    workspace_id = Scope.workspace_id(scope)

    assert is_list(Repo.all(from(i in Invitation, where: i.workspace_id == ^workspace_id)))
  end

  test "skip_workspace_guard opt-out passes" do
    assert is_list(Repo.all(Invitation, skip_workspace_guard: true))
  end

  test "scoped/2 without a workspace raises" do
    scope = Scope.for_account(account_fixture())

    assert_raise ArgumentError, ~r/without a workspace/, fn ->
      Repo.scoped(Invitation, scope)
    end
  end

  test "non-tenant tables are unaffected" do
    assert is_list(Repo.all(Dify.Accounts.Account))
  end
end
