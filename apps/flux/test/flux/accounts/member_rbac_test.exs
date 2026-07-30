defmodule Flux.Accounts.MemberRBACTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts

  setup do
    owner = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(owner, %{name: "RBAC WS"})
    owner_scope = Accounts.scope_for(owner)

    member = account_fixture()

    {:ok, membership} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: member.id,
        role: :editor
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace.id)
    member_scope = Accounts.scope_for(member)

    %{owner_scope: owner_scope, member_scope: member_scope, membership: membership}
  end

  test "member management is context-gated, not just UI-gated", %{
    member_scope: member_scope,
    membership: membership
  } do
    # An editor (no :workspace_member_manage) calling the CONTEXT directly
    # — bypassing the LiveView guard — must still be rejected.
    assert {:error, :unauthorized} =
             Accounts.update_member_role(member_scope, membership, :admin)

    assert {:error, :unauthorized} = Accounts.remove_member(member_scope, membership)

    assert {:error, :unauthorized} =
             Accounts.create_invitation(member_scope, %{email: "x@y.com", role: :normal})

    {[], errors} = Accounts.create_invitations(member_scope, ["a@b.com"], :normal)
    assert [{"a@b.com", {:error, :unauthorized}}] = errors

    assert {:error, :unauthorized} =
             Accounts.revoke_invitation(member_scope, Ecto.UUID.generate())
  end

  test "owners still manage members through the same paths", %{
    owner_scope: owner_scope,
    membership: membership
  } do
    assert {:ok, updated} = Accounts.update_member_role(owner_scope, membership, :admin)
    assert updated.role == :admin

    assert {:ok, {_invitation, _token}} =
             Accounts.create_invitation(owner_scope, %{email: "new@member.com", role: :normal})

    assert {:ok, _removed} = Accounts.remove_member(owner_scope, updated)
  end
end
