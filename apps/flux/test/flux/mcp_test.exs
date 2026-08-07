defmodule Flux.MCPTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.MCP

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "MCP WS"})
    scope = Accounts.scope_for(account)

    Application.put_env(:flux, :mcp_req_options, plug: {Req.Test, Flux.McpStub})
    on_exit(fn -> Application.delete_env(:flux, :mcp_req_options) end)

    %{scope: scope, workspace: workspace}
  end

  defp stub_server(parent) do
    Req.Test.stub(Flux.McpStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(parent, {:mcp, request["method"], Map.new(conn.req_headers)})

      case request["method"] do
        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-abc")
          |> Req.Test.json(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}
          })

        "notifications/initialized" ->
          Plug.Conn.send_resp(conn, 202, "")

        "tools/list" ->
          # SSE-framed, as streamable-HTTP servers may answer.
          sse =
            "event: message\ndata: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "tools" => [
                    %{
                      "name" => "get_time",
                      "description" => "Current time",
                      "inputSchema" => %{"type" => "object", "properties" => %{}}
                    }
                  ]
                }
              }) <> "\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, sse)

        "tools/call" ->
          %{"name" => "get_time", "arguments" => arguments} = request["params"]

          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "the time in #{arguments["zone"]} is noon"}
              ],
              "isError" => false
            }
          })
      end
    end)
  end

  test "registering a server caches its tools; refresh and delete work", %{scope: scope} do
    stub_server(self())

    {:ok, server} =
      MCP.create_server(scope, %{
        "name" => "Clock",
        "url" => "https://mcp.example.com/mcp",
        "headers" => %{"Authorization" => "Bearer sk-clock"}
      })

    assert [%{"name" => "get_time", "description" => "Current time"}] = server.tools
    assert server.encrypted_headers != nil

    # The handshake carried the auth header; tools/list echoed the session.
    assert_received {:mcp, "initialize", headers}
    assert headers["authorization"] == "Bearer sk-clock"
    assert_received {:mcp, "notifications/initialized", _headers}
    assert_received {:mcp, "tools/list", %{"mcp-session-id" => "session-abc"}}

    {:ok, refreshed} = MCP.refresh_server(scope, server.id)
    assert length(refreshed.tools) == 1

    {:ok, _deleted} = MCP.delete_server(scope, server.id)
    assert MCP.list_servers(scope) == []
  end

  test "invoke_for_workspace calls the tool through the engine path", %{
    scope: scope,
    workspace: workspace
  } do
    stub_server(self())

    {:ok, server} =
      MCP.create_server(scope, %{"name" => "Clock", "url" => "https://mcp.example.com/mcp"})

    assert {:ok, result} =
             Flux.Tools.invoke_for_workspace(
               workspace.id,
               "mcp:" <> server.id,
               "get_time",
               %{"zone" => "PST"}
             )

    assert result.text =~ "the time in PST is noon"
    assert result.status == 200

    # Another workspace's server id never resolves.
    other = account_fixture()
    {:ok, {other_ws, _}} = Accounts.create_workspace(other, %{name: "Other WS"})

    assert {:error, :not_found} =
             Flux.Tools.invoke_for_workspace(
               other_ws.id,
               "mcp:" <> server.id,
               "get_time",
               %{}
             )
  end

  test "mcp servers appear in the toolset picker shape", %{scope: scope} do
    stub_server(self())

    {:ok, server} =
      MCP.create_server(scope, %{"name" => "Clock", "url" => "https://mcp.example.com/mcp"})

    assert [%{id: id, name: "Clock (MCP)", operations: [operation]}] =
             Flux.Tools.mcp_toolsets(scope)

    assert id == "mcp:" <> server.id
    assert operation["operation_id"] == "get_time"
  end

  test "an unreachable server refuses registration", %{scope: scope} do
    Req.Test.stub(Flux.McpStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, "MCP server answered HTTP 500"} =
             MCP.create_server(scope, %{"name" => "Down", "url" => "https://down.example.com"})
  end
end
