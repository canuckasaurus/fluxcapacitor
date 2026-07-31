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

  test "entries are workspace-scoped", %{scope: scope} do
    :ok = Audit.record(scope, "mine.only")

    other = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(other, %{name: "Other WS"})
    other_scope = Accounts.scope_for(other)

    assert Audit.list(other_scope) == []
  end
end
