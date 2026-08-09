defmodule FluxWeb.Batch25WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch25 Web WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Structured App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _token, raw} = Chat.create_api_token(scope, app)

    authed =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, authed: authed, scope: scope, workspace: workspace, app: app}
  end

  @echo_schema %{
    "type" => "json_schema",
    "json_schema" => %{
      "name" => "echo_reply",
      "schema" => %{
        "type" => "object",
        "properties" => %{"echo" => %{"type" => "string"}},
        "required" => ["echo"]
      }
    }
  }

  describe "response_format json_schema" do
    test "answers validated JSON as message content", %{authed: authed} do
      response =
        authed
        |> post(
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "messages" => [%{"role" => "user", "content" => "please call the tool"}],
            "response_format" => @echo_schema
          })
        )
        |> json_response(200)

      assert [%{"finish_reason" => "stop", "message" => %{"content" => content}}] =
               response["choices"]

      assert {:ok, %{"echo" => echoed}} = Jason.decode(content)
      assert echoed =~ "please call the tool"
    end

    test "streaming delivers the JSON as one delta then stop", %{authed: authed} do
      conn =
        post(
          authed,
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "stream" => true,
            "messages" => [%{"role" => "user", "content" => "please call the tool"}],
            "response_format" => @echo_schema
          })
        )

      body = response(conn, 200)
      assert body =~ ~s(\\"echo\\")
      assert body =~ ~s("finish_reason":"stop")
      assert body =~ "data: [DONE]"
    end

    test "a schema the model cannot satisfy 502s after the corrective retry", %{authed: authed} do
      impossible = %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "impossible",
          "schema" => %{
            "type" => "object",
            "properties" => %{"never" => %{"type" => "integer"}},
            "required" => ["never"]
          }
        }
      }

      response =
        authed
        |> post(
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "messages" => [%{"role" => "user", "content" => "please call the tool"}],
            "response_format" => impossible
          })
        )
        |> json_response(502)

      assert response["error"]["message"] =~ "failed the schema"
    end

    test "combining response_format with tools is refused", %{authed: authed} do
      response =
        authed
        |> post(
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "messages" => [%{"role" => "user", "content" => "hi"}],
            "response_format" => @echo_schema,
            "tools" => [
              %{"type" => "function", "function" => %{"name" => "x", "parameters" => %{}}}
            ]
          })
        )
        |> json_response(400)

      assert response["error"]["message"] =~ "cannot be combined"
    end

    test "a malformed response_format is refused", %{authed: authed} do
      response =
        authed
        |> post(
          ~p"/v1/chat/completions",
          Jason.encode!(%{
            "messages" => [%{"role" => "user", "content" => "hi"}],
            "response_format" => %{"type" => "json_schema"}
          })
        )
        |> json_response(400)

      assert response["error"]["message"] =~ "response_format"
    end
  end

  describe "url source fetch-now" do
    test "an unknown source id errors honestly", %{scope: scope} do
      assert {:error, :not_found} =
               Flux.RAG.fetch_url_source_now(scope, Ecto.UUID.generate())
    end
  end
end
