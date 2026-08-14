defmodule FluxWeb.Batch36WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.RAG

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch36 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "document revisions" do
    test "replace keeps history and restore round-trips", %{scope: scope} do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "Rev KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, _v1} =
        RAG.add_document(scope, dataset, %{name: "policy.md", content: "version one"},
          replace: true
        )

      Oban.drain_queue(queue: :ingest)

      {:ok, _v2} =
        RAG.add_document(scope, dataset, %{name: "policy.md", content: "version two"},
          replace: true
        )

      Oban.drain_queue(queue: :ingest)

      assert [revision] = RAG.list_document_revisions(scope, dataset.id, "policy.md")
      assert revision.content == "version one"

      {:ok, _restored} = RAG.restore_document_revision(scope, revision.id)
      Oban.drain_queue(queue: :ingest)

      [document] = RAG.list_documents(scope, dataset.id)
      assert document.content == "version one"

      # Restoring stacked today's content as the newest revision.
      [newest | _rest] = RAG.list_document_revisions(scope, dataset.id, "policy.md")
      assert newest.content == "version two"
    end

    test "the embedded-token meter climbs with indexing", %{scope: scope} do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "Meter KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      assert dataset.embedded_tokens == 0

      {:ok, _document} =
        RAG.add_document(scope, dataset, %{name: "doc.md", content: "some words to embed here"})

      Oban.drain_queue(queue: :ingest)

      reloaded = RAG.get_dataset(scope, dataset.id)
      assert reloaded.embedded_tokens > 0
    end
  end

  describe "console branding" do
    test "the sidebar shows the workspace logo when set", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      {:ok, _workspace} =
        Accounts.set_console_logo(scope, "https://cdn.example.com/logo.png")

      conn = log_in_account(conn, account)
      {:ok, _lv, html} = live(conn, ~p"/console/apps")

      assert html =~ "https://cdn.example.com/logo.png"
    end
  end

  describe "URL import guardrails" do
    test "an unreachable URL surfaces an honest error", %{conn: conn, account: account} do
      # SSRF is disabled in the test env (hermetic — no DNS), so this
      # exercises the fetch-failure path; the SSRF path itself is pinned
      # by the batch-31 allowlist tests.
      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/fluxes")

      lv
      |> element("#import-url-form")
      |> render_submit(%{"url" => "http://127.0.0.1:9/flux.json"})

      assert render(lv) =~ "Could not fetch or import"
    end
  end
end
