defmodule FluxWeb.Batch28WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch28 Web WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Archive App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _token, raw} = Chat.create_api_token(scope, app)

    authed =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, authed: authed, scope: scope, workspace: workspace}
  end

  describe "dataset archives over the API" do
    test "export and import round-trip", %{authed: authed, scope: scope} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "API Portable",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, _doc} =
        Flux.RAG.add_document(scope, dataset, %{name: "a.md", content: "api archive text"})

      Oban.drain_queue(queue: :ingest)

      archive =
        authed
        |> get(~p"/v1/datasets/#{dataset.id}/export")
        |> json_response(200)

      assert archive["format"] == "flux-dataset/v1"
      assert [%{"name" => "a.md"}] = archive["documents"]

      imported =
        authed
        |> post(~p"/v1/datasets/import", Jason.encode!(archive))
        |> json_response(201)

      assert imported["documents"] == 1
      assert imported["name"] == "API Portable"

      Oban.drain_queue(queue: :ingest)
      [document] = Flux.RAG.list_documents(scope, imported["id"])
      assert document.status == :ready

      bad =
        authed
        |> post(~p"/v1/datasets/import", Jason.encode!(%{"format" => "nope"}))
        |> json_response(400)

      assert bad["message"] =~ "flux-dataset/v1"

      missing =
        authed
        |> get(~p"/v1/datasets/#{Ecto.UUID.generate()}/export")
        |> json_response(404)

      assert missing["code"] == "not_found"
    end
  end
end
