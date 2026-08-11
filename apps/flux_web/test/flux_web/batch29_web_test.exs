defmodule FluxWeb.Batch29WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch29 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "knowledge deep links" do
    test "?dataset&document selects and expands", %{conn: conn, scope: scope, account: account} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Linked DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, document} =
        Flux.RAG.add_document(scope, dataset, %{name: "cited.md", content: "cited text here"})

      Oban.drain_queue(queue: :ingest)

      {:ok, _lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/console/knowledge?dataset=#{dataset.id}&document=#{document.id}")

      assert html =~ "Linked DS"
      assert html =~ "cited.md"
      assert html =~ "cited text here"
    end
  end

  describe "citation ids" do
    test "knowledge retrieval citations carry dataset and document ids", %{scope: scope} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Citing DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, document} =
        Flux.RAG.add_document(scope, dataset, %{
          name: "source.md",
          content: "the flux capacitor needs 1.21 gigawatts"
        })

      Oban.drain_queue(queue: :ingest)

      {:ok, hits} = Flux.RAG.retrieve(scope, dataset.id, "gigawatts")
      assert [hit | _rest] = hits
      assert hit.document_id == document.id
      assert hit.dataset_id == dataset.id
    end
  end

  describe "visitor transcript" do
    test "the owning visitor downloads; strangers 404", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Transcript App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, app} = Chat.enable_site(scope, app)

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "visitor-t"})
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "save this")
      assert_receive {:done, _reply}, 5_000

      owner_conn =
        conn
        |> Plug.Test.init_test_session(%{"site_visitor" => "visitor-t"})
        |> get(~p"/site/#{app.site_token}/transcript/#{conversation.id}")

      assert response(owner_conn, 200) =~ "save this"

      stranger_conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"site_visitor" => "someone-else"})
        |> get(~p"/site/#{app.site_token}/transcript/#{conversation.id}")

      assert response(stranger_conn, 404)
    end
  end

  describe "dataset purge" do
    test "purges only trashed datasets", %{scope: scope} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Doomed DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      assert {:error, :not_trashed} = Flux.RAG.purge_dataset(scope, dataset.id)

      {:ok, _} = Flux.RAG.delete_dataset(scope, dataset)
      assert {:ok, _purged} = Flux.RAG.purge_dataset(scope, dataset.id)
      assert Flux.RAG.list_trashed_datasets(scope) == []
    end
  end
end
