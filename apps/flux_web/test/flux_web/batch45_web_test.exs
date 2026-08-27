defmodule FluxWeb.Batch45WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch45 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B45 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  describe "workspace-wide conversation search" do
    test "the apps page finds threads across apps and deep-links them", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope, %{"name" => "Search Target"})
      conversation = Chat.create_conversation(scope, app, %{title: "Untitled thread"})

      Flux.Repo.insert!(%Flux.Chat.Message{
        workspace_id: conversation.workspace_id,
        conversation_id: conversation.id,
        role: :user,
        content: "my flux capacitor is leaking plutonium"
      })

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/apps")

      html =
        lv
        |> form("#global-conversation-search", %{"q" => "leaking plutonium"})
        |> render_change()

      assert html =~ "global-search-results"
      assert html =~ "Search Target"
      assert html =~ "leaking plutonium"
      assert html =~ "conversation=#{conversation.id}"

      html =
        lv
        |> form("#global-conversation-search", %{"q" => "nothing-matches-this"})
        |> render_change()

      assert html =~ "No conversations matched"
    end
  end

  describe "webhook app binding" do
    test "the settings form binds an endpoint to one app", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope, %{"name" => "Webhook App"})

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/settings")

      html =
        lv
        |> form("#add-webhook-form", %{
          "url" => "https://hooks.example.com/app-bound",
          "app_id" => app.id,
          "events" => ["conversation.started"]
        })
        |> render_submit()

      assert html =~ "Webhook App"

      [endpoint] = Flux.Webhooks.list_endpoints(scope)
      assert endpoint.app_id == app.id
    end
  end

  describe "batch cost preview" do
    setup %{scope: scope} do
      graph = %{
        "nodes" => [
          %{
            "id" => "start",
            "type" => "start",
            "title" => "Start",
            "config" => %{
              "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
            }
          },
          %{
            "id" => "llm_1",
            "type" => "llm",
            "title" => "LLM",
            "config" => %{
              "provider_plugin_id" => "echo",
              "model" => "echo-1",
              "prompt" => "{{start.query}}"
            }
          },
          %{
            "id" => "answer_1",
            "type" => "answer",
            "title" => "Answer",
            "config" => %{"answer" => "{{llm_1.text}}"}
          }
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "llm_1"},
          %{
            "id" => "e2",
            "source" => "llm_1",
            "source_handle" => "default",
            "target" => "answer_1"
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Previewed"})
      {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
      %{workflow: workflow}
    end

    test "the confirm step projects rows × recent average", %{
      conn: conn,
      account: account,
      workflow: workflow,
      workspace: workspace,
      scope: scope
    } do
      # Two priced historical runs → 500 tokens / $0.02 per row average.
      for _n <- 1..2 do
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :succeeded,
          usage: %{
            "input_tokens" => 250,
            "output_tokens" => 250,
            "estimated_cost_usd" => 0.02
          }
        })
      end

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}/batches")

      upload =
        file_input(lv, "#batch-upload-form", :csv, [
          %{name: "rows.csv", content: "query\r\none\r\ntwo\r\nthree\r\n", type: "text/csv"}
        ])

      render_upload(upload, "rows.csv")
      html = lv |> form("#batch-upload-form") |> render_submit()

      assert html =~ "batch-projection"
      assert html =~ "3 rows"
      # 3 rows × 500 avg tokens = 1.5k; 3 × $0.02 = $0.06.
      assert html =~ "1.5k"
      assert html =~ "$0.06"

      # Cancel leaves nothing started.
      lv |> element("button[phx-click='cancel_pending_batch']") |> render_click()
      assert Workflows.list_batches(scope, workflow.id) == []
    end

    test "no history says so instead of guessing", %{
      conn: conn,
      account: account,
      workflow: workflow
    } do
      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}/batches")

      upload =
        file_input(lv, "#batch-upload-form", :csv, [
          %{name: "rows.csv", content: "query\r\none\r\n", type: "text/csv"}
        ])

      render_upload(upload, "rows.csv")
      html = lv |> form("#batch-upload-form") |> render_submit()

      assert html =~ "No completed runs to estimate from"
    end
  end

  describe "hardening: channel rate limit plumbing" do
    test "the channels scope carries the rate-limit pipeline", %{conn: conn, scope: scope} do
      # Rate limiting is disabled in test env; assert the wiring exists
      # by hitting the route and getting a normal (non-plug-crash)
      # response with a bad token.
      response =
        conn
        |> post(~p"/channels/email/emch_nope", %{"from" => "a@b.c", "text" => "hi"})

      assert response.status == 404

      app = echo_app(scope)
      {:ok, app} = Chat.enable_slack_channel(scope, app, "xoxb-rate-test")

      challenge =
        conn
        |> post(~p"/channels/slack/#{app.slack_channel_token}", %{
          "type" => "url_verification",
          "challenge" => "still-works"
        })
        |> json_response(200)

      assert challenge["challenge"] == "still-works"
    end
  end
end
