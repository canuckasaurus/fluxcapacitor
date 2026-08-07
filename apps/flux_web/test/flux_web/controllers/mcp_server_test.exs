defmodule FluxWeb.McpServerTest do
  @moduledoc "FluxCapacitor's own MCP endpoint: published fluxes as tools."
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "MCP Server WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        "name" => "Echo Answers",
        "description" => "Echoes the question back."
      })

    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _version} = Workflows.publish(scope, workflow)

    {:ok, _token, raw} = Chat.create_workspace_token(scope)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, scope: scope, workflow: workflow}
  end

  defp rpc(conn, method, params, id \\ 1) do
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    post(conn, ~p"/mcp", Jason.encode!(payload))
  end

  test "initialize advertises the tool capability", %{conn: conn} do
    response = json_response(rpc(conn, "initialize", %{}), 200)
    assert response["result"]["serverInfo"]["name"] == "fluxcapacitor"
    assert response["result"]["capabilities"]["tools"]
  end

  test "tools/list advertises published fluxes with input schemas", %{conn: conn} do
    response = json_response(rpc(conn, "tools/list", %{}), 200)

    assert [tool] = response["result"]["tools"]
    assert tool["name"] == "echo_answers"
    assert tool["description"] == "Echoes the question back."
    assert tool["inputSchema"]["properties"]["query"]["type"] == "string"
    assert tool["inputSchema"]["required"] == ["query"]
  end

  test "tools/call runs the flux synchronously and returns outputs", %{conn: conn} do
    response =
      rpc(conn, "tools/call", %{
        "name" => "echo_answers",
        "arguments" => %{"query" => "is this thing on?"}
      })
      |> json_response(200)

    assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
    assert response["result"]["isError"] == false
    assert Jason.decode!(text)["answer"] =~ "You said: is this thing on?"
  end

  test "unknown tools and unpublished fluxes answer JSON-RPC errors", %{conn: conn} do
    response =
      rpc(conn, "tools/call", %{"name" => "no_such_flux", "arguments" => %{}})
      |> json_response(200)

    assert response["error"]["code"] == -32602
  end

  test "a missing or invalid token is refused", %{conn: conn} do
    bare =
      conn
      |> delete_req_header("authorization")
      |> rpc("tools/list", %{})

    assert json_response(bare, 401)["error"]["message"] == "missing_token"

    wrong =
      conn
      |> put_req_header("authorization", "Bearer ws-not-a-real-token")
      |> rpc("tools/list", %{})

    assert json_response(wrong, 401)["error"]["message"] == "invalid_token"
  end

  defp echo_graph do
    %{
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
  end
end
