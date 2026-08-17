defmodule FluxWeb.Batch40WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch40 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B40 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  describe "external knowledge" do
    test "retrieval queries the endpoint and records become hits", %{scope: scope} do
      Application.put_env(:flux_rag, :req_options, plug: {Req.Test, Flux.ExternalKBStub})
      on_exit(fn -> Application.delete_env(:flux_rag, :req_options) end)

      {:ok, dataset} =
        RAG.connect_external_dataset(scope, %{
          "name" => "Legacy wiki",
          "endpoint" => "https://knowledge.example.com/retrieval",
          "knowledge_id" => "kb-88",
          "api_key" => "external-secret"
        })

      assert RAG.external?(dataset)

      Req.Test.stub(Flux.ExternalKBStub, fn conn ->
        assert ["Bearer external-secret"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(raw)
        assert payload["knowledge_id"] == "kb-88"
        assert payload["query"] == "flux capacitor"
        assert is_integer(payload["retrieval_setting"]["top_k"])

        Req.Test.json(conn, %{
          "records" => [
            %{"content" => "1.21 gigawatts", "score" => 0.92, "title" => "Power specs"},
            %{"content" => "88 miles per hour", "score" => 0.81}
          ]
        })
      end)

      {:ok, hits} = RAG.retrieve(scope, dataset.id, "flux capacitor")

      assert [first, second] = hits
      assert first.content == "1.21 gigawatts"
      assert first.document.name == "Power specs"
      assert first.score == 0.92
      # Untitled records fall back to the dataset name.
      assert second.document.name == "Legacy wiki"

      # retrieve_many merges external hits with the usual score sort.
      {:ok, merged} = RAG.retrieve_many(scope, [dataset.id], "flux capacitor", top_k: 1)
      assert [%{content: "1.21 gigawatts"}] = merged

      # No local documents on an external dataset.
      assert {:error, :external_dataset} =
               RAG.add_document(scope, dataset, %{name: "nope.md", content: "text"})
    end

    test "endpoint failures surface as errors, not empty knowledge", %{scope: scope} do
      Application.put_env(:flux_rag, :req_options, plug: {Req.Test, Flux.ExternalKBDownStub})
      on_exit(fn -> Application.delete_env(:flux_rag, :req_options) end)

      {:ok, dataset} =
        RAG.connect_external_dataset(scope, %{
          "name" => "Flaky KB",
          "endpoint" => "https://down.example.com/retrieval"
        })

      Req.Test.stub(Flux.ExternalKBDownStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert {:error, message} = RAG.retrieve(scope, dataset.id, "anything")
      assert message =~ "HTTP 500"

      # A bad scheme never becomes a dataset.
      assert {:error, _refused} =
               RAG.connect_external_dataset(scope, %{
                 "name" => "Bad",
                 "endpoint" => "ftp://nope.example.com"
               })
    end

    test "the knowledge page connects and shows the external card", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/knowledge")

      lv |> element("button[phx-click='new_external']") |> render_click()

      html =
        lv
        |> form("#external-connect-form", %{
          "name" => "Partner KB",
          "endpoint" => "https://kb.example.com/retrieval",
          "knowledge_id" => "kb-1",
          "api_key" => ""
        })
        |> render_submit()

      assert html =~ "Partner KB"
      assert html =~ "external-dataset-card"
      assert html =~ "kb.example.com/retrieval"
      # Document management stays hidden for external datasets.
      refute html =~ "Add documents"

      assert [dataset] = RAG.list_datasets(scope)
      assert dataset.external_knowledge_id == "kb-1"
    end
  end

  describe "embed origins" do
    test "the site CSP narrows to the configured origins", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      [csp] =
        conn
        |> get(~p"/site/#{app.site_token}")
        |> Plug.Conn.get_resp_header("content-security-policy")

      assert csp == "frame-ancestors *"

      {:ok, app} =
        Chat.update_app(scope, app, %{
          "embed_origins" => "https://www.example.com https://docs.example.com"
        })

      [locked] =
        conn
        |> get(~p"/site/#{app.site_token}")
        |> Plug.Conn.get_resp_header("content-security-policy")

      assert locked ==
               "frame-ancestors 'self' https://www.example.com https://docs.example.com"
    end

    test "the app page saves the origin list", %{conn: conn, account: account, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

      lv
      |> form("#embed-origins-form", %{"origins" => "https://only.example.com"})
      |> render_submit()

      assert Chat.get_app(scope, app.id).embed_origins == "https://only.example.com"
    end
  end

  describe "monitor assignment" do
    test "assign from the dropdown, filter by mine/unassigned", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{title: "Needs a human"})

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
      assert html =~ "Needs a human"

      # Open the conversation and assign it to ourselves.
      lv
      |> element("button[phx-click='select'][phx-value-conversation-id='#{conversation.id}']")
      |> render_click()

      html =
        lv
        |> form("#assign-#{conversation.id}", %{
          "conversation-id" => conversation.id,
          "account-id" => account.id
        })
        |> render_change()

      assert html =~ account.email

      # "Mine" keeps it; "Unassigned" hides it.
      html = lv |> form("#assignment-filter", %{"filter" => "mine"}) |> render_change()
      assert html =~ "Needs a human"

      html = lv |> form("#assignment-filter", %{"filter" => "unassigned"}) |> render_change()
      refute html =~ "Needs a human"
    end
  end

  describe "monitor canned replies" do
    test "save a reply and prefill a handoff answer with it", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_visitor"})
      site_scope = Chat.site_scope(app)
      {:ok, _conversation} = Chat.request_handoff(site_scope, app, conversation.id)

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}/monitor")

      html =
        lv
        |> form("#canned-reply-form", %{
          "title" => "greeting",
          "body" => "Hi! A human here - how can I help?"
        })
        |> render_submit()

      assert html =~ "canned-replies-card"
      assert html =~ "greeting"

      # Clicking the chip drops the body into that conversation's reply box.
      html =
        lv
        |> element(
          "button[phx-click='use_canned'][phx-value-conversation-id='#{conversation.id}']"
        )
        |> render_click()

      assert html =~ "Hi! A human here - how can I help?"
    end
  end

  describe "plugins credential pool" do
    test "a credential joins and leaves the load-balancing pool", %{
      conn: conn,
      account: account,
      workspace: workspace
    } do
      {:ok, encrypted} = Flux.Crypto.encrypt(workspace.id, Jason.encode!(%{"tag" => "a"}))

      credential =
        Flux.Repo.insert!(%Flux.Providers.ProviderCredential{
          workspace_id: workspace.id,
          plugin_id: "echo",
          name: "spare",
          is_default: true,
          encrypted_config: encrypted
        })

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/plugins")
      refute html =~ ">pooled<"

      html =
        lv
        |> element(
          "button[phx-click='toggle_balanced'][phx-value-credential-id='#{credential.id}']"
        )
        |> render_click()

      assert html =~ "pooled"

      assert Flux.Repo.get!(Flux.Providers.ProviderCredential, credential.id,
               skip_workspace_guard: true
             ).balanced
    end
  end

  describe "workspace settings moderation API" do
    test "saves and clears the endpoint", %{conn: conn, account: account, workspace: workspace} do
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/settings")
      assert html =~ "moderation-api-form"

      lv
      |> form("#moderation-api-form", %{
        "url" => "https://moderation.example.com/check",
        "action" => "flag",
        "fail" => "closed"
      })
      |> render_submit()

      assert %{action: "flag", fail: "closed"} =
               Flux.Guardrails.moderation_api_config(workspace.id)

      lv
      |> form("#moderation-api-form", %{"url" => "", "action" => "block", "fail" => "open"})
      |> render_submit()

      assert Flux.Guardrails.moderation_api_config(workspace.id) == nil
    end
  end
end
