defmodule Dify.RBACTest do
  use ExUnit.Case, async: true

  alias Dify.Accounts.{Account, Membership, Scope, Workspace}
  alias Dify.RBAC
  alias Dify.RBAC.Permission

  defp scope_with_role(role) do
    workspace = %Workspace{id: Ecto.UUID.generate(), name: "W"}
    account = %Account{id: Ecto.UUID.generate(), email: "t@example.com"}

    membership = %Membership{
      id: Ecto.UUID.generate(),
      workspace_id: workspace.id,
      account_id: account.id,
      role: role
    }

    account
    |> Scope.for_account()
    |> Scope.put_workspace(workspace, membership)
  end

  describe "permission catalog" do
    test "matches Dify's 45 permission points" do
      assert length(Permission.all()) == 45
      assert length(Permission.app_scope()) == 12
      assert length(Permission.dataset_scope()) == 15
      assert length(Permission.workspace_scope()) == 18
    end

    test "scope_of/1 classifies correctly" do
      assert Permission.scope_of(:app_edit) == :app
      assert Permission.scope_of(:dataset_edit) == :dataset
      assert Permission.scope_of(:workspace_member_manage) == :workspace
    end
  end

  describe "can?/3" do
    test "owner and admin hold every permission" do
      for role <- [:owner, :admin], permission <- Permission.all() do
        assert RBAC.can?(scope_with_role(role), permission),
               "expected #{role} to hold #{permission}"
      end
    end

    test "editor can build apps and datasets but not administer the workspace" do
      scope = scope_with_role(:editor)

      assert RBAC.can?(scope, :app_edit)
      assert RBAC.can?(scope, :app_create_and_management)
      assert RBAC.can?(scope, :dataset_edit)
      assert RBAC.can?(scope, :snippets_create_and_modify)
      assert RBAC.can?(scope, :credential_use)

      refute RBAC.can?(scope, :workspace_member_manage)
      refute RBAC.can?(scope, :plugin_install)
      refute RBAC.can?(scope, :credential_manage)
    end

    test "normal member can view and use but not edit" do
      scope = scope_with_role(:normal)

      assert RBAC.can?(scope, :app_preview)
      assert RBAC.can?(scope, :dataset_use)

      refute RBAC.can?(scope, :app_edit)
      refute RBAC.can?(scope, :dataset_edit)
      refute RBAC.can?(scope, :workspace_member_manage)
    end

    test "dataset_operator is knowledge-only" do
      scope = scope_with_role(:dataset_operator)

      for permission <- Permission.dataset_scope() do
        assert RBAC.can?(scope, permission)
      end

      refute RBAC.can?(scope, :app_edit)
      refute RBAC.can?(scope, :app_preview)
      refute RBAC.can?(scope, :workspace_member_manage)
    end

    test "unknown permission is denied even for owner" do
      refute RBAC.can?(scope_with_role(:owner), :made_up_permission)
    end

    test "scope without workspace membership is denied" do
      scope = Scope.for_account(%Account{id: Ecto.UUID.generate(), email: "x@example.com"})
      refute RBAC.can?(scope, :app_preview)
      refute RBAC.can?(nil, :app_preview)
    end
  end

  describe "authorize/3" do
    test "returns :ok / {:error, :unauthorized}" do
      assert RBAC.authorize(scope_with_role(:owner), :app_edit) == :ok
      assert RBAC.authorize(scope_with_role(:normal), :app_edit) == {:error, :unauthorized}
    end
  end

  describe "permissions_for_role/1" do
    test "role sets are subsets of the catalog" do
      all = MapSet.new(Permission.all())

      for role <- [:owner, :admin, :editor, :normal, :dataset_operator] do
        assert MapSet.subset?(RBAC.permissions_for_role(role), all)
      end
    end

    test "role hierarchy: normal < editor < admin" do
      normal = RBAC.permissions_for_role(:normal)
      editor = RBAC.permissions_for_role(:editor)
      admin = RBAC.permissions_for_role(:admin)

      assert MapSet.subset?(MapSet.delete(normal, :dataset_use), editor)
      assert MapSet.subset?(editor, admin)
    end
  end
end
