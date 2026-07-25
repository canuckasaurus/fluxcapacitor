defmodule Dify.Accounts.WorkspacesTest do
  use Dify.DataCase, async: true

  import Dify.AccountsFixtures

  alias Dify.Accounts
  alias Dify.Accounts.{Invitation, Membership, Scope}

  defp create_workspace_fixture(account, name \\ "Acme") do
    {:ok, {workspace, membership}} = Accounts.create_workspace(account, %{name: name})
    {workspace, membership}
  end

  defp scope_with_workspace(account) do
    Accounts.scope_for(account)
  end

  describe "create_workspace/2" do
    test "creates workspace with creator as current owner" do
      account = account_fixture()
      {workspace, membership} = create_workspace_fixture(account)

      assert workspace.name == "Acme"
      assert membership.role == :owner
      assert membership.current
      assert membership.workspace_id == workspace.id
      assert membership.account_id == account.id
    end

    test "second workspace becomes the current one" do
      account = account_fixture()
      {first, _} = create_workspace_fixture(account, "First")
      {second, _} = create_workspace_fixture(account, "Second")

      {current, membership} = Accounts.get_current_workspace(account)
      assert current.id == second.id
      assert membership.current

      assert {ws_ids, _} = Enum.unzip(Accounts.list_workspaces(account)) |> then(& &1)
      assert Enum.map(ws_ids, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])
    end

    test "rejects blank name" do
      account = account_fixture()
      assert {:error, changeset} = Accounts.create_workspace(account, %{name: ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "switch_workspace/2" do
    test "switches current membership" do
      account = account_fixture()
      {first, _} = create_workspace_fixture(account, "First")
      {_second, _} = create_workspace_fixture(account, "Second")

      assert {:ok, {switched, membership}} = Accounts.switch_workspace(account, first.id)
      assert switched.id == first.id
      assert membership.current
      assert membership.last_active_at

      {current, _} = Accounts.get_current_workspace(account)
      assert current.id == first.id
    end

    test "rejects non-member" do
      account = account_fixture()
      outsider = account_fixture()
      {workspace, _} = create_workspace_fixture(account)

      assert {:error, :not_a_member} = Accounts.switch_workspace(outsider, workspace.id)
    end
  end

  describe "scope_for/1" do
    test "builds scope with current workspace and role" do
      account = account_fixture()
      {workspace, _} = create_workspace_fixture(account)

      scope = Accounts.scope_for(account)
      assert Scope.workspace_id(scope) == workspace.id
      assert Scope.account_id(scope) == account.id
      assert Scope.role(scope) == :owner
    end

    test "scope without workspace when account has none" do
      account = account_fixture()
      scope = Accounts.scope_for(account)
      assert Scope.workspace_id(scope) == nil
      assert Scope.role(scope) == nil
    end
  end

  describe "member management" do
    setup do
      owner = account_fixture()
      {workspace, _} = create_workspace_fixture(owner)
      member = account_fixture()

      {:ok, membership} =
        %Membership{}
        |> Membership.changeset(%{
          workspace_id: workspace.id,
          account_id: member.id,
          role: :editor
        })
        |> Repo.insert()

      %{
        owner: owner,
        member: member,
        workspace: workspace,
        membership: membership,
        scope: scope_with_workspace(owner)
      }
    end

    test "list_members/1 returns all members", %{scope: scope, owner: owner, member: member} do
      members = Accounts.list_members(scope)
      assert length(members) == 2

      account_ids = Enum.map(members, fn {account, _m} -> account.id end)
      assert owner.id in account_ids
      assert member.id in account_ids
    end

    test "update_member_role/3 changes role", %{scope: scope, membership: membership} do
      assert {:ok, updated} = Accounts.update_member_role(scope, membership, :admin)
      assert updated.role == :admin
    end

    test "cannot grant owner via role update", %{scope: scope, membership: membership} do
      assert {:error, :invalid_role} = Accounts.update_member_role(scope, membership, :owner)
    end

    test "cannot demote the owner", %{scope: scope, owner: owner, workspace: workspace} do
      owner_membership =
        Repo.get_by!(Membership, workspace_id: workspace.id, account_id: owner.id)

      assert {:error, :cannot_change_owner_role} =
               Accounts.update_member_role(scope, owner_membership, :editor)
    end

    test "remove_member/2 removes non-owner", %{scope: scope, membership: membership} do
      assert {:ok, _} = Accounts.remove_member(scope, membership)
      assert Repo.get(Membership, membership.id) == nil
    end

    test "cannot remove owner or self", %{scope: scope, owner: owner, workspace: workspace} do
      owner_membership =
        Repo.get_by!(Membership, workspace_id: workspace.id, account_id: owner.id)

      assert {:error, :cannot_remove_owner} = Accounts.remove_member(scope, owner_membership)
    end

    test "transfer_ownership/2 swaps roles atomically", %{
      scope: scope,
      membership: membership,
      owner: owner,
      workspace: workspace
    } do
      assert {:ok, {promoted, demoted}} = Accounts.transfer_ownership(scope, membership)
      assert promoted.role == :owner
      assert demoted.role == :admin

      assert Repo.get_by!(Membership, workspace_id: workspace.id, account_id: owner.id).role ==
               :admin
    end

    test "single-owner constraint holds at the database level", %{
      workspace: workspace
    } do
      other = account_fixture()

      assert {:error, changeset} =
               %Membership{}
               |> Membership.changeset(%{
                 workspace_id: workspace.id,
                 account_id: other.id,
                 role: :owner
               })
               |> Repo.insert()

      assert %{workspace_id: [_]} = errors_on(changeset)
    end
  end

  describe "invitations" do
    setup do
      owner = account_fixture()
      {workspace, _} = create_workspace_fixture(owner)
      %{owner: owner, workspace: workspace, scope: scope_with_workspace(owner)}
    end

    test "create + accept invitation grants membership", %{scope: scope, workspace: workspace} do
      invitee = account_fixture()

      assert {:ok, {invitation, raw_token}} =
               Accounts.create_invitation(scope, %{email: invitee.email, role: :editor})

      assert invitation.workspace_id == workspace.id
      assert is_binary(raw_token)

      assert {:ok, membership} = Accounts.accept_invitation(invitee, raw_token)
      assert membership.role == :editor
      assert membership.workspace_id == workspace.id
      assert membership.account_id == invitee.id

      reloaded = Repo.get!(Invitation, invitation.id, skip_workspace_guard: true)
      assert reloaded.accepted_at
    end

    test "accepting twice fails", %{scope: scope} do
      invitee = account_fixture()

      {:ok, {_invitation, raw_token}} =
        Accounts.create_invitation(scope, %{email: invitee.email, role: :normal})

      assert {:ok, _} = Accounts.accept_invitation(invitee, raw_token)
      assert {:error, :already_accepted} = Accounts.accept_invitation(invitee, raw_token)
    end

    test "email must match the invitee", %{scope: scope} do
      other = account_fixture()

      {:ok, {_invitation, raw_token}} =
        Accounts.create_invitation(scope, %{email: "someone-else@example.com", role: :normal})

      assert {:error, :email_mismatch} = Accounts.accept_invitation(other, raw_token)
    end

    test "bulk invite splits successes and failures", %{scope: scope} do
      {oks, errors} =
        Accounts.create_invitations(
          scope,
          ["a@example.com", "bad-email", "b@example.com"],
          :normal
        )

      assert length(oks) == 2
      assert [{"bad-email", {:error, _}}] = errors
    end

    test "duplicate pending invite for same email is rejected", %{scope: scope} do
      assert {:ok, _} =
               Accounts.create_invitation(scope, %{email: "dup@example.com", role: :normal})

      assert {:error, changeset} =
               Accounts.create_invitation(scope, %{email: "dup@example.com", role: :normal})

      assert %{workspace_id: [_]} = errors_on(changeset)
    end

    test "revoke removes pending invitation", %{scope: scope} do
      {:ok, {invitation, _}} =
        Accounts.create_invitation(scope, %{email: "x@example.com", role: :normal})

      assert [_] = Accounts.list_pending_invitations(scope)
      assert {:ok, _} = Accounts.revoke_invitation(scope, invitation.id)
      assert [] = Accounts.list_pending_invitations(scope)
    end

    test "invalid token", _ctx do
      account = account_fixture()
      assert {:error, :not_found} = Accounts.accept_invitation(account, "garbage")
    end
  end
end
