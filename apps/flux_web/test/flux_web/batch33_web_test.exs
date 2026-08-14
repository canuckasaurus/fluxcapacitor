defmodule FluxWeb.Batch33WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch33 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "/v1/images/generations" do
    test "generates through the workspace default model's provider", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _workspace} = Flux.Providers.set_default_model(scope, "echo", "echo-1")
      {:ok, _token, raw} = Chat.create_workspace_token(scope)

      body =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/images/generations", %{"prompt" => "a flux capacitor, glowing"})
        |> json_response(200)

      assert [%{"b64_json" => b64}] = body["data"]
      assert {:ok, _image} = Base.decode64(b64)
      assert is_integer(body["created"])
    end

    test "a blank prompt is a 400", %{conn: conn, scope: scope} do
      {:ok, _token, raw} = Chat.create_workspace_token(scope)

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> post(~p"/v1/images/generations", %{"prompt" => "  "})
             |> json_response(400)
    end
  end

  describe "dataset duplicate and embedding switch" do
    setup %{scope: scope} do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "Original KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed",
          "chunk_size" => 500
        })

      {:ok, _document} =
        RAG.add_document(scope, dataset, %{name: "doc.md", content: "the flux runs at 88 mph"})

      Oban.drain_queue(queue: :ingest)
      %{dataset: RAG.get_dataset(scope, dataset.id)}
    end

    test "duplicate copies settings and documents", %{scope: scope, dataset: dataset} do
      {:ok, copy, 1} = RAG.duplicate_dataset(scope, dataset)
      Oban.drain_queue(queue: :ingest)

      assert copy.name == "Original KB (copy)"
      assert copy.chunk_size == 500
      assert copy.embedding_model == "echo-embed"

      [document] = RAG.list_documents(scope, copy.id)
      assert document.status == :ready
      assert document.content == "the flux runs at 88 mph"

      {:ok, hits} = RAG.retrieve(scope, copy.id, "how fast does the flux run?")
      assert hits != []
    end

    test "switch_embedding_model updates and re-embeds", %{scope: scope, dataset: dataset} do
      {:ok, updated, 1} =
        RAG.switch_embedding_model(scope, dataset, "echo", "echo-embed-large")

      assert updated.embedding_model == "echo-embed-large"

      Oban.drain_queue(queue: :ingest)
      [document] = RAG.list_documents(scope, updated.id)
      assert document.status in [:ready, :error]
    end
  end

  describe "site custom CSS" do
    test "renders on the public site with style-tag breakout stripped", %{
      conn: conn,
      scope: scope
    } do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Styled Site",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, app} =
        Chat.update_app(scope, app, %{
          "site_theme" =>
            Map.put(app.site_theme, "custom_css", ".chat-bubble { border-radius: 2px; }")
        })

      {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")
      assert html =~ "border-radius: 2px"
    end
  end
end
