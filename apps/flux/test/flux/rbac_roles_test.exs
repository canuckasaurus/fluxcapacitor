defmodule Flux.RBACRolesTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.RBAC

  setup do
    owner = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(owner, %{name: "Roles WS"})
    owner_scope = Accounts.scope_for(owner)

    member = account_fixture()

    {:ok, membership} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: member.id,
        role: :normal
      })
      |> Flux.Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace.id)

    %{
      owner_scope: owner_scope,
      member: member,
      membership: membership,
      workspace: workspace
    }
  end

  test "custom roles grant exactly their permission subset", %{
    owner_scope: owner_scope,
    member: member,
    membership: membership
  } do
    # A normal member cannot edit apps.
    member_scope = Accounts.scope_for(member)
    refute RBAC.can?(member_scope, :app_edit)

    {:ok, role} =
      RBAC.create_role(owner_scope, %{
        "name" => "App Builder",
        "permissions" => ["app_edit", "app_test_and_run"]
      })

    {:ok, _} = RBAC.assign_custom_role(owner_scope, membership, role.id)

    # Freshly built scope picks up the custom role's grants — and ONLY those.
    member_scope = Accounts.scope_for(member)
    assert RBAC.can?(member_scope, :app_edit)
    assert RBAC.can?(member_scope, :app_test_and_run)
    refute RBAC.can?(member_scope, :app_view_layout)
    refute RBAC.can?(member_scope, :workspace_member_manage)

    # Unassigning reverts to built-in grants.
    membership = Flux.Repo.get!(Flux.Accounts.Membership, membership.id)
    {:ok, _} = RBAC.assign_custom_role(owner_scope, membership, nil)
    member_scope = Accounts.scope_for(member)
    refute RBAC.can?(member_scope, :app_edit)
    assert RBAC.can?(member_scope, :app_view_layout)
  end

  test "deleting a role reverts assigned members to built-in grants", %{
    owner_scope: owner_scope,
    member: member,
    membership: membership
  } do
    {:ok, role} =
      RBAC.create_role(owner_scope, %{"name" => "Temp", "permissions" => ["app_edit"]})

    {:ok, _} = RBAC.assign_custom_role(owner_scope, membership, role.id)
    assert RBAC.can?(Accounts.scope_for(member), :app_edit)

    {:ok, _} = RBAC.delete_role(owner_scope, role.id)
    member_scope = Accounts.scope_for(member)
    refute RBAC.can?(member_scope, :app_edit)
    assert RBAC.can?(member_scope, :app_view_layout)
  end

  test "role management requires workspace_role_manage and validates permissions", %{
    owner_scope: owner_scope,
    member: member
  } do
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} =
             RBAC.create_role(member_scope, %{"name" => "Nope", "permissions" => []})

    assert {:error, changeset} =
             RBAC.create_role(owner_scope, %{"name" => "Bad", "permissions" => ["made_up"]})

    assert %{permissions: [message]} = errors_on(changeset)
    assert message =~ "made_up"
  end

  test "the owner cannot be bound to a custom role", %{owner_scope: owner_scope} do
    {:ok, role} = RBAC.create_role(owner_scope, %{"name" => "Trap", "permissions" => []})

    owner_membership = owner_scope.membership

    assert {:error, :cannot_change_owner_role} =
             RBAC.assign_custom_role(owner_scope, owner_membership, role.id)
  end
end
