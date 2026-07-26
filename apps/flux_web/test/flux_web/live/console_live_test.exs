defmodule FluxWeb.ConsoleLiveTest do
  use FluxWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts

  describe "authentication and onboarding" do
    test "anonymous users are sent to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/accounts/log-in"}}} = live(conn, ~p"/console")
    end

    test "accounts without a workspace are sent to onboarding", %{conn: conn} do
      conn = log_in_account(conn, account_fixture())
      assert {:error, {:redirect, %{to: "/console/workspaces/new"}}} = live(conn, ~p"/console")
    end

    test "workspace creation onboarding creates and enters the workspace", %{conn: conn} do
      account = account_fixture()
      conn = log_in_account(conn, account)

      {:ok, lv, _html} = live(conn, ~p"/console/workspaces/new")

      lv
      |> form("#workspace-form", workspace: %{name: "Rocket Team"})
      |> render_submit()

      assert_redirect(lv, "/console")
      assert {%{name: "Rocket Team"}, _membership} = Accounts.get_current_workspace(account)
    end
  end

  describe "console sections" do
    setup %{conn: conn} do
      account = account_fixture()
      {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Acme"})
      %{conn: log_in_account(conn, account), account: account, workspace: workspace}
    end

    test "dashboard shows workspace and section links", %{conn: conn, workspace: workspace} do
      {:ok, _lv, html} = live(conn, ~p"/console")
      assert html =~ "Welcome to #{workspace.name}"
      assert html =~ "Flux Creator"
      assert html =~ "Knowledge"
      assert html =~ "Plugins"
      assert html =~ "Members"
    end

    test "section screens render", %{conn: conn} do
      for {path, marker} <- [
            {~p"/console/fluxes", "Flux Creator"},
            {~p"/console/knowledge", "Knowledge"},
            {~p"/console/plugins", "Plugins"}
          ] do
        {:ok, _lv, html} = live(conn, path)
        assert html =~ marker
      end
    end

    test "members screen lists the owner and can invite", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/console/members")
      assert html =~ account.email
      assert html =~ "Invite people"

      lv
      |> form("#invite-form", invite: %{emails: "new.teammate@example.com", role: "editor"})
      |> render_submit()

      html = render(lv)
      assert html =~ "new.teammate@example.com"
      assert html =~ "Pending invitations"
    end

    test "sidebar switcher lists workspaces and switching works", %{
      conn: conn,
      account: account,
      workspace: workspace
    } do
      {:ok, {second, _}} = Accounts.create_workspace(account, %{name: "Second Base"})

      {:ok, _lv, html} = live(conn, ~p"/console")
      assert html =~ workspace.name
      assert html =~ "Second Base"
      assert html =~ "New workspace"

      conn = post(conn, ~p"/console/workspaces/switch/#{workspace.id}")
      assert redirected_to(conn) == ~p"/console"

      {current, _} = Accounts.get_current_workspace(account)
      assert current.id == workspace.id

      conn = build_conn() |> log_in_account(account)
      conn = post(conn, ~p"/console/workspaces/switch/#{second.id}")
      assert redirected_to(conn) == ~p"/console"
      {current, _} = Accounts.get_current_workspace(account)
      assert current.id == second.id
    end

    test "switching to a non-member workspace is rejected", %{conn: conn} do
      outsider = account_fixture()
      {:ok, {foreign, _}} = Accounts.create_workspace(outsider, %{name: "Foreign"})

      conn = post(conn, ~p"/console/workspaces/switch/#{foreign.id}")
      assert redirected_to(conn) == ~p"/console"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not a member"
    end

    test "invited account can accept and lands in the workspace", %{
      account: account,
      workspace: workspace
    } do
      invitee = account_fixture()

      scope = Accounts.scope_for(account)

      {:ok, {_invitation, raw_token}} =
        Accounts.create_invitation(scope, %{email: invitee.email, role: :normal})

      invitee_conn = build_conn() |> log_in_account(invitee)
      conn = get(invitee_conn, ~p"/invitations/accept/#{raw_token}")
      assert redirected_to(conn) == ~p"/console"

      {current_workspace, membership} = Accounts.get_current_workspace(invitee)
      assert current_workspace.id == workspace.id
      assert membership.role == :normal
    end
  end
end
