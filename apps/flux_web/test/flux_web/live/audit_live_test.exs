defmodule FluxWeb.AuditLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Audit UI WS"})
    scope = Accounts.scope_for(account)
    %{conn: conn, account: account, scope: scope, workspace: workspace}
  end

  test "owner sees recorded actions", %{conn: conn, account: account, scope: scope} do
    {:ok, _app} =
      Chat.create_app(scope, %{
        "name" => "Audited",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    conn = log_in_account(conn, account)
    {:ok, _lv, html} = live(conn, ~p"/console/audit")

    assert html =~ "app.create"
    assert html =~ account.email
  end

  test "normal members are turned away", %{conn: conn, workspace: workspace} do
    member = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: member.id,
        role: :normal
      })
      |> Flux.Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace.id)

    conn = log_in_account(conn, member)
    assert {:error, {:live_redirect, %{to: "/console"}}} = live(conn, ~p"/console/audit")
  end
end
