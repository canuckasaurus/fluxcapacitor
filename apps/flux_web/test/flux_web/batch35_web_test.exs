defmodule FluxWeb.Batch35WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch35 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "visitor identity on the site" do
    test "the pre-chat form stores name and email", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "ID Site",
          "provider_plugin_id" => "echo",
          "model" => "echo-1",
          "collect_visitor_info" => true
        })

      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, lv, html} = live(conn, ~p"/site/#{app.site_token}")
      assert html =~ "visitor-identity-form"

      html =
        lv
        |> element("#visitor-identity-form")
        |> render_submit(%{"name" => "Marty", "email" => "marty@example.com"})

      refute html =~ "visitor-identity-form"

      site_scope = Chat.site_scope(app)
      [conversation] = Flux.Repo.all(Flux.Repo.scoped(Flux.Chat.Conversation, site_scope))
      assert conversation.visitor_name == "Marty"
      assert conversation.visitor_email == "marty@example.com"
    end
  end

  describe "document expiry" do
    test "the nightly sweep disables expired documents", %{scope: scope} do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "Expiring KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, document} =
        RAG.add_document(scope, dataset, %{name: "promo.md", content: "sale ends soon"})

      Oban.drain_queue(queue: :ingest)

      yesterday = DateTime.add(DateTime.utc_now(:second), -1, :day)
      {:ok, _document} = RAG.set_document_expiry(scope, document.id, yesterday)

      assert {:ok, 1} = RAG.disable_expired_documents()

      reloaded = Flux.Repo.get!(Flux.RAG.Document, document.id, skip_workspace_guard: true)
      refute reloaded.enabled

      # Retrieval no longer sees it.
      {:ok, hits} = RAG.retrieve(scope, dataset.id, "sale ends soon")
      assert hits == []

      # A second sweep is a no-op.
      assert {:ok, 0} = RAG.disable_expired_documents()
    end
  end

  describe "palette deep search" do
    test "?q= answers conversations and runs with deep links", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Palette Web App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation =
        Chat.create_conversation(scope, app, %{title: "Gigawatts questions"})

      conn = log_in_account(conn, account)

      body =
        conn
        |> get(~p"/console/palette?q=gigawatts")
        |> json_response(200)

      assert [entry] = body["entries"]
      assert entry["kind"] == "conversation"
      assert entry["label"] == "Gigawatts questions"
      assert entry["url"] =~ "/console/apps/#{app.id}/monitor?conversation=#{conversation.id}"

      # Short queries answer nothing (the static list handles those).
      assert %{"entries" => []} =
               build_conn()
               |> log_in_account(account)
               |> get(~p"/console/palette?q=gi")
               |> json_response(200)
    end

    test "the monitor deep link opens the conversation selected", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Deep Link App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{title: "Opened by palette"})

      conn = log_in_account(conn, account)

      {:ok, _lv, html} =
        live(conn, ~p"/console/apps/#{app.id}/monitor?conversation=#{conversation.id}")

      assert html =~ "Opened by palette"
    end

    test "the runs deep link expands the run", %{conn: conn, scope: scope, account: account} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Deep Run Flux"})

      run =
        Flux.Repo.insert!(%Workflows.WorkflowRun{
          workspace_id: Flux.Accounts.Scope.workspace_id(scope),
          workflow_id: workflow.id,
          status: :succeeded,
          started_by: "palette-test"
        })

      conn = log_in_account(conn, account)
      {:ok, _lv, html} = live(conn, ~p"/console/runs?run=#{run.id}")

      assert html =~ "run-detail-#{run.id}"
      assert html =~ "palette-test"
    end
  end
end
