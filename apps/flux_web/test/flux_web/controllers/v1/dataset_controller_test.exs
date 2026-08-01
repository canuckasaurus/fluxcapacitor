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

  test "missing datasets 404 and bad params 400", %{conn: conn} do
    assert conn
           |> post(~p"/v1/datasets/#{Ecto.UUID.generate()}/retrieve", %{"query" => "x"})
           |> json_response(404)

    assert conn |> post(~p"/v1/datasets", %{}) |> json_response(400)
  end
end
