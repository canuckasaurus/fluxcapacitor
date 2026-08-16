defmodule FluxWeb.Batch39WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch39 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B39 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end

  describe "dataset file API" do
    test "create-by-file extracts and indexes; update-by-text revises", %{
      conn: conn,
      scope: scope
    } do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "File KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, _token, raw} = Chat.create_workspace_token(scope)
      conn = put_req_header(conn, "authorization", "Bearer #{raw}")

      path = Path.join(System.tmp_dir!(), "b39-api-#{System.unique_integer([:positive])}.md")
      File.write!(path, "gigawatts and jigowatts")
      on_exit(fn -> File.rm(path) end)

      upload = %Plug.Upload{path: path, filename: "notes.md", content_type: "text/markdown"}

      body =
        conn
        |> post(~p"/v1/datasets/#{dataset.id}/document/create-by-file", %{"file" => upload})
        |> json_response(200)

      document_id = body["document"]["id"]
      assert body["document"]["name"] == "notes.md"

      updated =
        conn
        |> post(
          ~p"/v1/datasets/#{dataset.id}/documents/#{document_id}/update-by-text",
          %{"text" => "now it says something else"}
        )
        |> json_response(200)

      assert updated["document"]["id"] == document_id

      [document] = Flux.RAG.list_documents(scope, dataset.id)
      assert document.content == "now it says something else"

      # The old content survived as a revision.
      assert [revision] = Flux.RAG.list_document_revisions(scope, dataset.id, "notes.md")
      assert revision.content =~ "gigawatts"
    end
  end

  describe "idempotency over the wire" do
    test "the same key replays the stored response", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      request = fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("idempotency-key", "retry-123")
        |> post(~p"/v1/chat-messages", %{
          "query" => "idempotent hello",
          "response_mode" => "blocking"
        })
      end

      first = request.()
      first_body = json_response(first, 200)
      assert get_resp_header(first, "idempotency-replayed") == []

      second = request.()
      second_body = json_response(second, 200)
      assert get_resp_header(second, "idempotency-replayed") == ["true"]
      assert second_body["message_id"] == first_body["message_id"]

      # Only one conversation was actually created.
      site_scope = Chat.site_scope(app)
      conversations = Flux.Repo.all(Flux.Repo.scoped(Flux.Chat.Conversation, site_scope))
      assert length(conversations) == 1
    end
  end

  describe "email channel webhook" do
    test "inbound mail becomes a turn and the reply mails back", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_email_channel(scope, app)

      drain_emails()

      response =
        conn
        |> post(~p"/channels/email/#{app.email_channel_token}", %{
          "sender" => "biff@example.com",
          "subject" => "hello",
          "body-plain" => "make like a tree"
        })
        |> json_response(202)

      assert response["status"] == "replying"

      Process.sleep(1_500)

      assert_email_sent(fn email ->
        [{_name, to}] = email.to
        to == "biff@example.com" and email.subject =~ "Re: your message"
      end)

      assert build_conn()
             |> post(~p"/channels/email/emch_wrong", %{"sender" => "x@y.z", "text" => "hi"})
             |> json_response(404)
    end
  end

  describe "passkey login endpoints" do
    test "challenge mints and bad assertions bounce", %{conn: conn} do
      challenge_response =
        conn
        |> post(~p"/accounts/passkeys/login-challenge")
        |> json_response(200)

      assert is_binary(challenge_response["challenge"])
      assert is_binary(challenge_response["rp_id"])

      bounced =
        build_conn()
        |> post(~p"/accounts/passkeys/login", %{
          "raw_id" => "AAAA",
          "authenticator_data" => "AAAA",
          "signature" => "AAAA",
          "client_data_json" => "AAAA"
        })

      assert redirected_to(bounced) == ~p"/accounts/log-in"
    end

    test "the settings page shows the passkey card; login page the button", %{
      conn: conn,
      account: account
    } do
      logged = log_in_account(conn, account)
      {:ok, _lv, html} = live(logged, ~p"/accounts/settings")
      assert html =~ "Add a passkey"

      {:ok, _lv, login_html} = live(build_conn(), ~p"/accounts/log-in")
      assert login_html =~ "passkey-login"
    end
  end

  describe "live visitor presence" do
    test "a site tab shows up in the monitor's count", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, _site_lv, _html} = live(conn, ~p"/site/#{app.site_token}")

      assert FluxWeb.SitePresence.visitor_count(app.id) >= 1
    end
  end

  describe "run bookmarks" do
    test "starring pins the run to the top", %{conn: conn, scope: scope, account: account} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Starrable"})

      run =
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: Flux.Accounts.Scope.workspace_id(scope),
          workflow_id: workflow.id,
          status: :succeeded
        })

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/runs")
      assert html =~ "☆"

      html =
        lv
        |> element(~s(button[phx-click="toggle_run_star"][phx-value-id="#{run.id}"]))
        |> render_click()

      assert html =~ "★"
      assert MapSet.member?(Accounts.favorite_ids(account, "run"), run.id)
    end
  end

  describe "dashboard member usage" do
    test "the who-is-spending card renders", %{conn: conn, scope: scope, account: account} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Cardable"})

      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: Flux.Accounts.Scope.workspace_id(scope),
        workflow_id: workflow.id,
        status: :succeeded,
        started_by: "someone@example.com",
        usage: %{"input_tokens" => 42, "output_tokens" => 0}
      })

      conn = log_in_account(conn, account)
      {:ok, _lv, html} = live(conn, ~p"/console")

      assert html =~ "Who is spending"
      assert html =~ "someone@example.com"
    end
  end

  describe "guardrail presets in settings" do
    test "one click appends the pattern", %{conn: conn, scope: scope, account: account} do
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/settings")

      assert html =~ "guardrail-presets"

      {_label, email_pattern} = List.first(Flux.Guardrails.presets())

      lv
      |> element(~s(#guardrail-presets button), "+ emails")
      |> render_click()

      workspace_id = Flux.Accounts.Scope.workspace_id(scope)
      assert %{patterns: patterns} = Flux.Guardrails.config(workspace_id)
      assert email_pattern in patterns
    end
  end

  describe "app budget and email channel cards" do
    test "chat settings save the budget; the channel card mints", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      app = echo_app(scope)
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")

      assert html =~ "Monthly cost budget"
      assert html =~ "Enable email channel"

      lv
      |> element(~s(button[phx-click="enable_email_channel"]))
      |> render_click()

      assert render(lv) =~ "/channels/email/emch_"
    end
  end
end
