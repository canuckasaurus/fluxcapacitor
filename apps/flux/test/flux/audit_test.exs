defmodule Flux.AuditTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Audit
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Audit WS"})
    %{scope: Accounts.scope_for(account), workspace: workspace, account: account}
  end

  test "record and list", %{scope: scope, account: account} do
    :ok = Audit.record(scope, "test.action", resource_type: "thing", resource_id: "t1")

    [entry] = Audit.list(scope)
    assert entry.action == "test.action"
    assert entry.resource_type == "thing"
    assert entry.actor_id == account.id
  end

  test "app lifecycle and publishing are audited", %{scope: scope} do
    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Audited App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, app} = Chat.enable_site(scope, app)
    {:ok, _} = Chat.delete_app(scope, app)

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Audited Flux"})
    {:ok, _version} = Flux.Workflows.publish(scope, workflow)

    actions = scope |> Audit.list() |> Enum.map(& &1.action)

    assert "app.create" in actions
    assert "app.site_enable" in actions
    assert "app.delete" in actions
    assert "workflow.publish" in actions
  end

  test "member, role, token, and trigger mutations are audited", %{
    scope: scope,
    workspace: workspace
  } do
    # Member role change + removal.
    member = account_fixture()

    {:ok, membership} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: member.id,
        role: :normal
      })
      |> Flux.Repo.insert()

    {:ok, _} = Accounts.update_member_role(scope, membership, :editor)

    # Custom role lifecycle.
    {:ok, role} = Flux.RBAC.create_role(scope, %{"name" => "Aud", "permissions" => ["app_edit"]})
    membership = Flux.Repo.get!(Flux.Accounts.Membership, membership.id)
    {:ok, _} = Flux.RBAC.assign_custom_role(scope, membership, role.id)
    {:ok, _} = Flux.RBAC.delete_role(scope, role.id)

    membership = Flux.Repo.get!(Flux.Accounts.Membership, membership.id)
    {:ok, _} = Accounts.remove_member(scope, membership)

    # API token + trigger lifecycle.
    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Aud Flux"})
    {:ok, token, _raw} = Flux.Workflows.create_api_token(scope, workflow)
    {:ok, _} = Flux.Workflows.revoke_api_token(scope, token.id)
    {:ok, trigger} = Flux.Workflows.create_trigger(scope, workflow, %{"type" => "webhook"})
    {:ok, _} = Flux.Workflows.delete_trigger(scope, trigger.id)

    actions = scope |> Flux.Audit.list(100) |> Enum.map(& &1.action)

    for action <- ~w(member.role_change member.remove role.create role.assign role.delete
                     api_token.create api_token.revoke trigger.create trigger.delete) do
      assert action in actions, "expected #{action} to be audited"
    end
  end

  test "entries are workspace-scoped", %{scope: scope} do
    :ok = Audit.record(scope, "mine.only")

    other = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(other, %{name: "Other WS"})
    other_scope = Accounts.scope_for(other)

    assert Audit.list(other_scope) == []
  end
end
