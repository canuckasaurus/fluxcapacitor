defmodule FluxWeb.WorkspaceSettingsLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Settings WS"})
    %{conn: log_in_account(conn, account), account: account, workspace: workspace}
  end

  test "owner renames and deletes the workspace", %{conn: conn, workspace: workspace} do
    {:ok, lv, html} = live(conn, ~p"/console/settings")
    assert html =~ "Settings WS"
    assert html =~ "Danger zone"

    lv |> form("#rename-form", %{"name" => "Renamed WS"}) |> render_submit()
    assert Flux.Repo.get!(Flux.Accounts.Workspace, workspace.id).name == "Renamed WS"

    # Wrong confirmation is refused; exact name deletes.
    html = lv |> form("#delete-workspace-form", %{"confirm" => "nope"}) |> render_submit()
    assert html =~ "Type the workspace name exactly"

    assert {:error, {:redirect, %{to: "/console"}}} =
             lv |> form("#delete-workspace-form", %{"confirm" => "Renamed WS"}) |> render_submit()

    assert Flux.Repo.get(Flux.Accounts.Workspace, workspace.id) == nil
  end

  test "SCIM card enables, shows the token once, and disables", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/console/settings")
    assert html =~ "SCIM provisioning"
    assert html =~ "/scim/v2"

    html = lv |> element("button", "Enable SCIM") |> render_click()
    assert html =~ "scim_"
    assert html =~ "shown once"
    assert html =~ "Rotate token"

    html = lv |> element("button", "Disable") |> render_click()
    refute html =~ "Rotate token"
    assert html =~ "Enable SCIM"
  end

  test "normal members see no rename or danger zone", %{conn: _conn, workspace: workspace} do
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

    {:ok, _lv, html} = build_conn() |> log_in_account(member) |> live(~p"/console/settings")
    refute html =~ "Danger zone"
    refute html =~ "rename-form"
  end
end
