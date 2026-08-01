defmodule FluxWeb.V1.ChatMessageControllerTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "API WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "API Echo",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _token, raw} = Chat.create_api_token(scope, app)

    %{conn: put_req_header(conn, "authorization", "Bearer #{raw}"), scope: scope, app: app}
  end

  test "rejects missing or invalid tokens", %{app: _app} do
    conn = build_conn() |> post(~p"/v1/chat-messages", %{"query" => "hi"})
    assert conn.status == 401

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer app-invalid")
      |> post(~p"/v1/chat-messages", %{"query" => "hi"})

    assert conn.status == 401
  end

  test "blocking mode returns the full answer", %{conn: conn} do
    conn =
      post(conn, ~p"/v1/chat-messages", %{
        "query" => "ping from api",
        "response_mode" => "blocking"
      })

    body = json_response(conn, 200)
    assert body["event"] == "message"
    assert body["answer"] =~ "You said: ping from api"
    assert body["conversation_id"]
    assert body["metadata"]["usage"]["output_tokens"] == 12
  end

  test "image files attach to the message and reach the provider", %{
    conn: conn,
    scope: scope,
    app: app
  } do
    # A 1x1 transparent PNG.
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      )

    path = Path.join(System.tmp_dir!(), "pixel.png")
    File.write!(path, png)
    upload = %Plug.Upload{path: path, filename: "pixel.png", content_type: "image/png"}

    file_id =
      conn
      |> post(~p"/v1/files/upload", %{"file" => upload})
      |> json_response(200)
      |> Map.fetch!("id")

    body =
      conn
      |> post(~p"/v1/chat-messages", %{
        "query" => "what is in this picture?",
        "response_mode" => "blocking",
        "files" => [
          %{"type" => "image", "transfer_method" => "local_file", "upload_file_id" => file_id}
        ]
      })
      |> json_response(200)

    # The echo provider acknowledges images it received via the SDK.
    assert body["answer"] =~ "[1 image(s)]"

    # The stored user message carries the attachment metadata.
    [conversation] = Chat.list_conversations(scope, app.id)
    [user_message | _rest] = Chat.list_messages(scope, conversation.id)
    assert [%{"name" => "pixel.png", "content_type" => "image/png"}] = user_message.files

    # Unknown and non-image file ids are ignored, not errors.
    body =
      conn
      |> post(~p"/v1/chat-messages", %{
        "query" => "no image here",
        "response_mode" => "blocking",
        "files" => [
          %{
            "type" => "image",
            "transfer_method" => "local_file",
            "upload_file_id" => Ecto.UUID.generate()
          }
        ]
      })
      |> json_response(200)

    refute body["answer"] =~ "image(s)"
  end

  test "streaming mode emits message events then message_end", %{conn: conn} do
    conn = post(conn, ~p"/v1/chat-messages", %{"query" => "stream me"})

    assert conn.state == :chunked
    events = parse_sse(conn.resp_body)

    answer =
      events
      |> Enum.filter(&(&1["event"] == "message"))
      |> Enum.map_join("", & &1["answer"])

    assert answer =~ "You said: stream me"

    assert %{"event" => "message_end", "metadata" => %{"usage" => usage}} = List.last(events)
    assert usage["output_tokens"] == 12
  end

  test "continues a conversation by id", %{conn: conn} do
    first =
      post(conn, ~p"/v1/chat-messages", %{"query" => "first", "response_mode" => "blocking"})
      |> json_response(200)

    second =
      post(conn, ~p"/v1/chat-messages", %{
        "query" => "second",
        "conversation_id" => first["conversation_id"],
        "response_mode" => "blocking"
      })
      |> json_response(200)

    assert second["conversation_id"] == first["conversation_id"]
    assert second["answer"] =~ "You said: second"
  end

  test "rejects a foreign conversation id", %{scope: scope, app: app} do
    other_conversation = Chat.create_conversation(scope, app)

    other_account = account_fixture()
    {:ok, _} = Accounts.create_workspace(other_account, %{name: "Other"})
    other_scope = Accounts.scope_for(other_account)

    {:ok, other_app} =
      Chat.create_app(other_scope, %{
        "name" => "Other App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _t, other_raw} = Chat.create_api_token(other_scope, other_app)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{other_raw}")
      |> post(~p"/v1/chat-messages", %{
        "query" => "sneaky",
        "conversation_id" => other_conversation.id,
        "response_mode" => "blocking"
      })

    assert json_response(conn, 404)["code"] == "not_found"
  end

  test "requires query", %{conn: conn} do
    conn = post(conn, ~p"/v1/chat-messages", %{})
    assert json_response(conn, 400)["code"] == "invalid_param"
  end

  defp parse_sse(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end
end
