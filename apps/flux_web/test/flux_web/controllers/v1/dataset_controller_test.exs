defmodule FluxWeb.V1.DatasetControllerTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "DS API WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "DS App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _token, raw} = Chat.create_api_token(scope, app)
    %{conn: put_req_header(conn, "authorization", "Bearer #{raw}"), scope: scope}
  end

  test "full dataset lifecycle over the API", %{conn: conn} do
    # Create (embedding defaults to the first available embedding model — echo).
    body = conn |> post(~p"/v1/datasets", %{"name" => "API KB"}) |> json_response(200)
    dataset_id = body["id"]
    assert body["name"] == "API KB"

    body = conn |> get(~p"/v1/datasets") |> json_response(200)
    assert [%{"name" => "API KB", "embedding_model" => "echo-embed"}] = body["data"]

    # Add a text document; it starts pending, then Oban indexes it.
    body =
      conn
      |> post(~p"/v1/datasets/#{dataset_id}/document/create-by-text", %{
        "name" => "policy.txt",
        "text" => "Refund policy: refunds are honored within 30 days of purchase."
      })
      |> json_response(200)

    assert body["document"]["status"] == "pending"
    Oban.drain_queue(queue: :ingest)

    body = conn |> get(~p"/v1/datasets/#{dataset_id}/documents") |> json_response(200)
    assert [%{"status" => "ready", "segment_count" => count}] = body["data"]
    assert count >= 1

    # Retrieve.
    body =
      conn
      |> post(~p"/v1/datasets/#{dataset_id}/retrieve", %{
        "query" => "when are refunds honored?",
        "top_k" => 2
      })
      |> json_response(200)

    assert [record | _] = body["records"]
    assert record["segment"]["content"] =~ "30 days"
    assert record["document"]["name"] == "policy.txt"
  end

  test "create-by-url, segments, and deletes over the API", %{conn: conn} do
    body = conn |> post(~p"/v1/datasets", %{"name" => "URL KB"}) |> json_response(200)
    dataset_id = body["id"]

    # URL ingestion through the stubbed fetcher.
    Application.put_env(:flux_rag, :req_options, plug: {Req.Test, Flux.DsApiStub})
    on_exit(fn -> Application.delete_env(:flux_rag, :req_options) end)

    Req.Test.stub(Flux.DsApiStub, fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html><body>Shipping takes three days.</body></html>")
    end)

    body =
      conn
      |> post(~p"/v1/datasets/#{dataset_id}/document/create-by-url", %{
        "url" => "https://docs.example.com/shipping"
      })
      |> json_response(200)

    document_id = body["document"]["id"]
    assert body["document"]["name"] == "docs.example.com/shipping"
    Oban.drain_queue(queue: :ingest)

    # Segments listing includes the enabled flag.
    body =
      conn
      |> get(~p"/v1/datasets/#{dataset_id}/documents/#{document_id}/segments")
      |> json_response(200)

    assert [%{"content" => content, "enabled" => true, "position" => 0}] = body["data"]
    assert content =~ "three days"

    # Document delete → gone from the list; then the dataset itself.
    assert conn
           |> delete(~p"/v1/datasets/#{dataset_id}/documents/#{document_id}")
           |> json_response(200) == %{"result" => "success"}

    body = conn |> get(~p"/v1/datasets/#{dataset_id}/documents") |> json_response(200)
    assert body["data"] == []

    # Deleting a document from the wrong dataset 404s.
    assert conn
           |> delete(~p"/v1/datasets/#{dataset_id}/documents/#{Ecto.UUID.generate()}")
           |> json_response(404)

    assert conn |> delete(~p"/v1/datasets/#{dataset_id}") |> json_response(200)
    assert conn |> get(~p"/v1/datasets") |> json_response(200) == %{"data" => []}
  end

  test "missing datasets 404 and bad params 400", %{conn: conn} do
    assert conn
           |> post(~p"/v1/datasets/#{Ecto.UUID.generate()}/retrieve", %{"query" => "x"})
           |> json_response(404)

    assert conn |> post(~p"/v1/datasets", %{}) |> json_response(400)
  end
end
