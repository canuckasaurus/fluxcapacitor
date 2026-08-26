defmodule FluxWeb.Batch44WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch44 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B44 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  describe "admin workspace suspension" do
    test "suspend refuses the API and banners the console; unsuspend restores", %{
      conn: conn,
      account: account,
      workspace: workspace,
      scope: scope
    } do
      Application.put_env(:flux, :instance_admins, [account.email])
      on_exit(fn -> Application.delete_env(:flux, :instance_admins) end)

      app = echo_app(scope)
      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      logged = log_in_account(conn, account)
      {:ok, lv, _html} = live(logged, ~p"/console/admin")

      html =
        lv
        |> element(
          "button[phx-click='suspend_workspace'][phx-value-workspace-id='#{workspace.id}']"
        )
        |> render_click()

      assert html =~ "suspended"

      # API tokens now refuse with the honest code.
      refused =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/chat-messages", %{"query" => "hi", "user" => "u1"})
        |> json_response(403)

      assert refused["code"] == "workspace_suspended"

      # The console shows the banner.
      {:ok, _dash, dash_html} = live(logged, ~p"/console")
      assert dash_html =~ "workspace-suspended-banner"

      lv
      |> element(
        "button[phx-click='unsuspend_workspace'][phx-value-workspace-id='#{workspace.id}']"
      )
      |> render_click()

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> post(~p"/v1/chat-messages", %{
               "query" => "hi",
               "user" => "u1",
               "response_mode" => "blocking"
             })
             |> json_response(200)
    end
  end

  describe "workspace settings governance" do
    test "model allowlist checkboxes save and filter", %{
      conn: conn,
      account: account,
      workspace: workspace
    } do
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/settings")
      assert html =~ "model-allowlist-form"

      lv
      |> form("#model-allowlist-form", %{"allowed" => ["echo|echo-1"]})
      |> render_submit()

      assert Accounts.model_allowlist(workspace.id) == ["echo|echo-1"]
    end

    test "auto-resolve and console-ip settings save", %{
      conn: conn,
      account: account,
      workspace: workspace
    } do
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/settings")
      assert html =~ "auto-resolve-form"

      lv |> form("#auto-resolve-form", %{"days" => "14"}) |> render_submit()

      refreshed = Flux.Repo.get!(Flux.Accounts.Workspace, workspace.id)
      assert refreshed.custom_config["auto_resolve_days"] == 14

      lv |> element("#console-ip-toggle") |> render_click()

      refreshed = Flux.Repo.get!(Flux.Accounts.Workspace, workspace.id)
      assert refreshed.custom_config["console_ip_allowlist"] == true
    end

    test "console access refuses off-list addresses when enforced", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      # Allowlist an address that isn't the test client's 127.0.0.1.
      {:ok, _workspace} = Flux.IPAllowlist.configure(scope, "203.0.113.7")
      {:ok, _workspace} = Accounts.set_console_ip_allowlist(scope, true)

      conn = log_in_account(conn, account)
      response = get(conn, ~p"/console")
      assert response.status == 403
      assert response.resp_body =~ "restricts console access"
    end
  end

  describe "per-app guardrail overrides" do
    test "the app page saves the scope", %{conn: conn, account: account, scope: scope} do
      app = echo_app(scope)

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")
      assert html =~ "app-guardrails-card"

      lv
      |> form("#app-guardrails-form", %{"mode" => "extra", "patterns" => "internal-\\w+"})
      |> render_submit()

      saved = Chat.get_app(scope, app.id)
      assert saved.guardrails_mode == "extra"
      assert saved.guardrail_patterns == "internal-\\w+"
    end
  end

  describe "AI-drafted replies in the monitor" do
    test "the draft lands in the reply box", %{conn: conn, account: account, scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{title: "Needs a draft"})
      {:ok, _message} = Chat.human_reply(scope, conversation.id, "hello?")

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}/monitor")

      lv
      |> element("button[phx-click='select'][phx-value-conversation-id='#{conversation.id}']")
      |> render_click()

      lv |> element("#draft-reply-#{conversation.id}") |> render_click()

      # The echo model answers fast; poll the rendered page for the
      # prefilled reply box.
      drafted? =
        Enum.reduce_while(1..40, false, fn _try, _acc ->
          html = render(lv)

          if html =~ "Drafting" do
            Process.sleep(100)
            {:cont, false}
          else
            {:halt, true}
          end
        end)

      assert drafted?
    end
  end

  describe "pending-work inbox" do
    test "paused runs and handoffs surface with links", %{
      conn: conn,
      account: account,
      scope: scope,
      workspace: workspace
    } do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Inbox Flux"})

      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :paused,
        snapshot: %{"node_id" => "ask", "prompt" => "Approve?"}
      })

      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_inbox"})
      {:ok, _flagged} = Chat.request_handoff(Chat.site_scope(app), app, conversation.id)

      conn = log_in_account(conn, account)
      {:ok, _lv, html} = live(conn, ~p"/console/inbox")

      assert html =~ "Inbox Flux"
      assert html =~ "human input"
      assert html =~ "B44 Web App"
      assert html =~ "1 waiting"
      assert html =~ "Open monitor"
    end
  end

  describe "provider rate caps on the plugins page" do
    test "the cap form saves per provider", %{conn: conn, account: account, workspace: workspace} do
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/plugins")
      assert html =~ "rate-cap-form-openai"

      lv
      |> form("#rate-cap-form-openai", %{"plugin-id" => "openai", "cap" => "30"})
      |> render_submit()

      assert Flux.Providers.provider_rate_cap(workspace.id, "openai") == 30

      lv
      |> form("#rate-cap-form-openai", %{"plugin-id" => "openai", "cap" => ""})
      |> render_submit()

      assert Flux.Providers.provider_rate_cap(workspace.id, "openai") == nil
    end
  end

  describe "toolset re-import from the tools page" do
    @spec_v1 ~S({"openapi": "3.0.0", "info": {"title": "Mini"},
      "servers": [{"url": "https://mini.example.com"}],
      "paths": {"/a": {"get": {"operationId": "opA"}}}})

    @spec_v2 ~S({"openapi": "3.0.0", "info": {"title": "Mini"},
      "servers": [{"url": "https://mini.example.com"}],
      "paths": {"/a": {"get": {"operationId": "opA"}},
                "/b": {"get": {"operationId": "opB"}}}})

    test "paste-updating a toolset refreshes operations", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      {:ok, toolset} = Flux.Tools.create_toolset(scope, "Mini", @spec_v1)

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/tools")

      lv |> element("button[phx-click='expand'][phx-value-id='#{toolset.id}']") |> render_click()

      html =
        lv
        |> form("#reimport-paste-#{toolset.id}", %{
          "toolset-id" => toolset.id,
          "spec" => @spec_v2
        })
        |> render_submit()

      assert html =~ "1 operation(s) added"

      {:ok, refreshed} = {:ok, Flux.Tools.get_toolset(scope, toolset.id)}
      assert length(refreshed.operations) == 2
    end
  end
end
