defmodule FluxWeb.V1.AppResourceControllerTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Res WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Res App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _t, raw} = Chat.create_api_token(scope, app)
    %{conn: put_req_header(conn, "authorization", "Bearer #{raw}"), scope: scope, app: app}
  end

  test "parameters returns app model info", %{conn: conn} do
    body = conn |> get(~p"/v1/parameters") |> json_response(200)
    assert body["model"]["name"] == "echo-1"
  end

  test "conversations and messages list after a blocking chat", %{conn: conn} do
    post(conn, ~p"/v1/chat-messages", %{"query" => "hi", "response_mode" => "blocking"})

    body = conn |> get(~p"/v1/conversations") |> json_response(200)
    assert [%{"id" => conversation_id}] = body["data"]

    body =
      conn |> get(~p"/v1/messages?conversation_id=#{conversation_id}") |> json_response(200)

    roles = Enum.map(body["data"], & &1["role"])
    assert roles == ["user", "assistant"]
    assert Enum.at(body["data"], 1)["content"] =~ "You said: hi"
  end

  test "feedback sets and clears a rating", %{conn: conn, scope: scope} do
    first =
      post(conn, ~p"/v1/chat-messages", %{"query" => "rate me", "response_mode" => "blocking"})
      |> json_response(200)

    assert conn
           |> post(~p"/v1/messages/#{first["message_id"]}/feedbacks", %{"rating" => "like"})
           |> json_response(200) == %{"result" => "success"}

    messages = Chat.list_messages(scope, first["conversation_id"])
    assert Enum.any?(messages, &(&1.feedback == :like))

    conn |> post(~p"/v1/messages/#{first["message_id"]}/feedbacks", %{"rating" => nil})
    messages = Chat.list_messages(scope, first["conversation_id"])
    refute Enum.any?(messages, & &1.feedback)
  end

  test "stop on a finished message says not_streaming", %{conn: conn} do
    first =
      post(conn, ~p"/v1/chat-messages", %{"query" => "x", "response_mode" => "blocking"})
      |> json_response(200)

    body =
      conn
      |> post(~p"/v1/chat-messages/#{first["message_id"]}/stop", %{})
      |> json_response(400)

    assert body["code"] == "not_streaming"
  end

  test "flux tokens are rejected", %{scope: scope} do
    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "W"})
    {:ok, _t, raw} = Flux.Workflows.create_api_token(scope, workflow)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get(~p"/v1/parameters")

    assert json_response(conn, 403)["code"] == "invalid_token_kind"
  end
end
