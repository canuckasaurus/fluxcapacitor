defmodule FluxWeb.OpenAICompatTest do
  @moduledoc "POST /v1/chat/completions in OpenAI's wire format."
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Compat WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Compat App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "system_prompt" => "You echo."
      })

    {:ok, _token, raw} = Chat.create_api_token(scope, app)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, scope: scope, app: app}
  end

  test "blocking completion answers in OpenAI shape", %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/v1/chat/completions",
        Jason.encode!(%{
          "model" => "ignored-by-design",
          "messages" => [
            %{"role" => "user", "content" => "hello compat"}
          ]
        })
      )

    response = json_response(conn, 200)
    assert response["object"] == "chat.completion"
    assert String.starts_with?(response["id"], "chatcmpl-")
    assert response["model"] == "echo/echo-1"

    assert [%{"message" => %{"role" => "assistant", "content" => content}}] =
             response["choices"]

    assert content =~ "You said: hello compat"
    assert response["usage"]["completion_tokens"] == 12
    assert response["usage"]["total_tokens"] > 12
  end

  test "content-part arrays and streaming chunks work", %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/v1/chat/completions",
        Jason.encode!(%{
          "stream" => true,
          "messages" => [
            %{
              "role" => "user",
              "content" => [%{"type" => "text", "text" => "streamed hello"}]
            }
          ]
        })
      )

    assert response_content_type(conn, :"event-stream") =~ "text/event-stream"
    body = conn.resp_body

    assert body =~ "chat.completion.chunk"
    assert body =~ ~s("content":"You ")
    assert body =~ ~s("content":"streamed ")
    assert body =~ ~s("finish_reason":"stop")
    assert String.trim(body) |> String.ends_with?("data: [DONE]")
  end

  test "chatflow apps bridge through their published flux", %{conn: _conn, scope: scope} do
    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Bridge Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "config" => %{
            "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "llm_1",
          "type" => "llm",
          "title" => "LLM",
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "prompt" => "{{start.query}}"
          }
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "config" => %{"answer" => "{{llm_1.text}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "llm_1"},
        %{"id" => "e2", "source" => "llm_1", "source_handle" => "default", "target" => "answer_1"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _version} = Flux.Workflows.publish(scope, workflow)

    {:ok, chatflow} =
      Chat.create_app(scope, %{
        "name" => "Bridge App",
        "mode" => "advanced_chat",
        "workflow_id" => workflow.id
      })

    {:ok, _token, raw} = Chat.create_api_token(scope, chatflow)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/v1/chat/completions",
        Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "through the flux"}]})
      )

    response = json_response(conn, 200)
    assert response["model"] == "flux/Bridge Flux"

    assert [%{"message" => %{"content" => content}}] = response["choices"]
    assert content =~ "You said: through the flux"
  end

  test "per-app rate limits override the pipeline default", %{scope: scope, app: app} do
    Application.put_env(:flux_web, :rate_limit_enabled, true)
    on_exit(fn -> Application.put_env(:flux_web, :rate_limit_enabled, false) end)

    {:ok, app} = Chat.update_app(scope, app, %{"rate_limit_per_minute" => 2})

    opts =
      FluxWeb.Plugs.RateLimit.init(
        name: "compat-test-#{System.unique_integer([:positive])}",
        by: :service,
        limit: 120
      )

    hit = fn ->
      build_conn(:post, "/v1/chat/completions")
      |> Plug.Conn.assign(:service_app, app)
      |> FluxWeb.Plugs.RateLimit.call(opts)
    end

    first = hit.()
    assert Plug.Conn.get_resp_header(first, "x-ratelimit-limit") == ["2"]
    refute first.halted

    _second = hit.()
    third = hit.()
    assert third.halted
    assert third.status == 429
  end

  test "chatflow apps, quota, and missing tokens refuse in OpenAI error shape", %{
    conn: conn,
    scope: scope,
    app: app
  } do
    # Spent quota → 429.
    {:ok, _} = Chat.update_app(scope, app, %{"daily_token_limit" => 1})
    conversation = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "burn tokens")
    assert_receive {:done, _}, 5_000

    conn2 =
      post(
        conn,
        ~p"/v1/chat/completions",
        Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "more?"}]})
      )

    assert %{"error" => %{"type" => "rate_limit_error"}} = json_response(conn2, 429)

    # No token at all → the service pipeline's 401.
    bare =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/chat/completions", Jason.encode!(%{"messages" => []}))

    assert json_response(bare, 401)["code"] == "unauthorized"
  end
end
