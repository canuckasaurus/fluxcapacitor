defmodule FluxWeb.Batch30WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch30 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "site maintenance page" do
    test "a disabled site shows the friendly page, not a 404", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Sleepy App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, app} = Chat.enable_site(scope, app)
      {:ok, app} = Chat.disable_site(scope, app)

      {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")
      assert html =~ "site-maintenance"
      assert html =~ "Sleepy App"
      assert html =~ "back soon"
    end

    test "a bogus token still renders not-found", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/site/site_definitely_not_real")
      assert html =~ "This app is not available."
    end
  end

  describe "run JSON export" do
    test "downloads the run with its trace", %{conn: conn, scope: scope, account: account} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Export Flux"})

      graph =
        update_in(workflow.graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")

            node ->
              node
          end)
        end)

      {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
      {:ok, run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "export me"})

      assert_receive {:run_finished, _finished}, 10_000

      body =
        conn
        |> log_in_account(account)
        |> get(~p"/console/runs/#{run.id}/export")
        |> response(200)

      payload = Jason.decode!(body)
      assert payload["id"] == run.id
      assert payload["status"] == "succeeded"
      assert is_list(payload["node_executions"])
      assert payload["node_executions"] != []
    end
  end
end
