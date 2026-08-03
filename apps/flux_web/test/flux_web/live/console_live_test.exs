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

    test "?locale=fr renders the console in French", %{conn: conn, workspace: workspace} do
      # The Locale plug remembers ?locale= in the session, so the LiveView
      # mount (via the on_mount hook) picks it up too.
      conn = get(conn, ~p"/console?locale=fr")
      {:ok, _lv, html} = live(conn, ~p"/console")
      assert html =~ "Bienvenue dans #{workspace.name}"
      assert html =~ "Créateur de Flux"
      assert html =~ "Étiquetage"
      assert html =~ "Exécutions"
    end

    test "?locale=es renders the console in Spanish", %{conn: conn, workspace: workspace} do
      conn = get(conn, ~p"/console?locale=es")
      {:ok, _lv, html} = live(conn, ~p"/console")
      assert html =~ "Bienvenido a #{workspace.name}"
      assert html =~ "Etiquetado"
      assert html =~ "Archivos"
      assert html =~ "Ejecuciones"
    end

    test "dashboard usage rolls up chat and run activity", %{conn: conn, account: account} do
      scope = Accounts.scope_for(account)

      # Empty workspace: the placeholder shows.
      {:ok, _lv, html} = live(conn, ~p"/console")
      assert html =~ "Usage (last 14 days)"
      assert html =~ "Nothing to report yet"

      {:ok, app} =
        Flux.Chat.create_app(scope, %{
          "name" => "Usage App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Flux.Chat.create_conversation(scope, app)
      {:ok, _u, _a} = Flux.Chat.send_message(scope, app, conversation, "count me")
      assert_receive {:done, _final}, 5_000

      {:ok, _lv, html} = live(conn, ~p"/console")
      refute html =~ "Nothing to report yet"
      assert html =~ "Top apps by tokens"
      assert html =~ "Usage App"

      summary = Flux.Usage.workspace_summary(scope)
      assert summary.tokens.replies == 1
      assert summary.tokens.output == 12
      assert [%{name: "Usage App", replies: 1}] = summary.top_apps
      assert summary.knowledge == %{datasets: 0, documents: 0, segments: 0}
    end

    test "section screens render", %{conn: conn} do
      for {path, marker} <- [
            {~p"/console/fluxes", "Flux Creator"},
            {~p"/console/knowledge", "Knowledge"},
            {~p"/console/plugins", "Plugins"},
            {~p"/console/files", "Everything the workspace has stored"},
            {~p"/console/notifications", "All quiet on the temporal front"}
          ] do
        {:ok, _lv, html} = live(conn, path)
        assert html =~ marker
      end
    end

    test "the instance admin panel gates on FLUX_ADMIN_EMAILS", %{
      conn: conn,
      account: account,
      workspace: workspace
    } do
      # Not an admin: bounced to the dashboard.
      assert {:error, {:live_redirect, %{to: "/console"}}} = live(conn, ~p"/console/admin")

      Application.put_env(:flux, :instance_admins, [account.email])
      on_exit(fn -> Application.delete_env(:flux, :instance_admins) end)

      {:ok, lv, html} = live(conn, ~p"/console/admin")
      assert html =~ "Instance admin"
      assert html =~ workspace.name

      lv
      |> element("#admin-ws-#{workspace.id} form")
      |> render_change(%{"workspace-id" => workspace.id, "plan" => "team"})

      assert Flux.Features.plan_for_workspace(workspace.id) == "team"
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
