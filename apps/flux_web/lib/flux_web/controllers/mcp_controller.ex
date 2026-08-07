defmodule FluxWeb.McpController do
  @moduledoc """
  FluxCapacitor as an MCP server: `POST /mcp` speaks JSON-RPC 2.0
  (Streamable HTTP, plain-JSON responses). A workspace `ws-` API key in
  the Authorization header names the workspace; every published flux is
  advertised as a callable tool whose input schema comes from its start
  variables. `tools/call` runs the flux synchronously and returns its
  outputs.
  """
  use FluxWeb, :controller

  alias Flux.Accounts.Scope
  alias Flux.Workflows

  @protocol_version "2025-03-26"

  def handle(conn, params) do
    with {:ok, workspace_id} <- authenticate(conn) do
      dispatch(conn, workspace_id, params)
    else
      {:error, code} ->
        conn
        |> put_status(401)
        |> json(%{
          "jsonrpc" => "2.0",
          "id" => params["id"],
          "error" => %{"code" => -32000, "message" => to_string(code)}
        })
    end
  end

  defp authenticate(conn) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, workspace_id, _token} <- Flux.Chat.fetch_workspace_by_token(raw) do
      {:ok, workspace_id}
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, :missing_token}
    end
  end

  defp dispatch(conn, _workspace_id, %{"method" => "initialize", "id" => id}) do
    result(conn, id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "fluxcapacitor", "version" => "0.2.0"}
    })
  end

  # Notifications carry no id and expect no body.
  defp dispatch(conn, _workspace_id, %{"method" => "notifications/" <> _rest}) do
    send_resp(conn, 202, "")
  end

  defp dispatch(conn, workspace_id, %{"method" => "tools/list", "id" => id}) do
    tools =
      for {tool_name, workflow, version} <- published_tools(workspace_id) do
        %{
          "name" => tool_name,
          "description" => workflow.description || "FluxCapacitor flux: #{workflow.name}",
          "inputSchema" => input_schema(version.graph)
        }
      end

    result(conn, id, %{"tools" => tools})
  end

  defp dispatch(conn, workspace_id, %{"method" => "tools/call", "id" => id} = params) do
    name = get_in(params, ["params", "name"]) || ""
    arguments = get_in(params, ["params", "arguments"]) || %{}
    scope = %Scope{workspace: %Flux.Accounts.Workspace{id: workspace_id}}

    case Enum.find(published_tools(workspace_id), fn {tool_name, _w, _v} ->
           tool_name == name
         end) do
      nil ->
        error(conn, id, -32602, "unknown tool: #{name}")

      {_tool_name, workflow, _version} ->
        case Workflows.run_published_sync(scope, workflow, arguments) do
          {:ok, %{status: :succeeded} = run} ->
            result(conn, id, %{
              "content" => [%{"type" => "text", "text" => Jason.encode!(run.outputs)}],
              "isError" => false
            })

          {:ok, %{error: run_error}} ->
            result(conn, id, %{
              "content" => [%{"type" => "text", "text" => run_error || "run failed"}],
              "isError" => true
            })

          {:error, reason} ->
            error(conn, id, -32000, format_reason(reason))
        end
    end
  end

  defp dispatch(conn, _workspace_id, %{"method" => method} = params) do
    error(conn, params["id"], -32601, "method not supported: #{method}")
  end

  defp dispatch(conn, _workspace_id, params) do
    error(conn, params["id"], -32600, "invalid JSON-RPC request")
  end

  # Published fluxes as tools; names are slugs, deduped by first-8 id
  # suffix on collision so every advertised name stays callable.
  defp published_tools(workspace_id) do
    scope = %Scope{workspace: %Flux.Accounts.Workspace{id: workspace_id}}

    entries =
      for workflow <- Workflows.list_workflows(scope),
          version = Workflows.serving_version(scope, workflow),
          version != nil,
          do: {slug(workflow.name), workflow, version}

    entries
    |> Enum.group_by(fn {slug, _w, _v} -> slug end)
    |> Enum.flat_map(fn
      {slug, [{_slug, workflow, version}]} ->
        [{slug, workflow, version}]

      {slug, collisions} ->
        for {_slug, workflow, version} <- collisions do
          {slug <> "_" <> String.slice(workflow.id, 0, 8), workflow, version}
        end
    end)
    |> Enum.sort_by(fn {name, _w, _v} -> name end)
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "flux"
      slug -> slug
    end
  end

  defp input_schema(graph) do
    variables =
      graph
      |> Map.get("nodes", [])
      |> Enum.find_value([], fn node ->
        node["type"] == "start" && get_in(node, ["config", "variables"])
      end)

    properties =
      Map.new(variables, fn variable ->
        {variable["name"],
         %{
           "type" => json_type(variable["type"]),
           "description" => variable["label"] || variable["name"]
         }}
      end)

    required = for %{"required" => true, "name" => name} <- variables, do: name

    %{"type" => "object", "properties" => properties, "required" => required}
  end

  defp json_type("number"), do: "number"
  defp json_type(_text_like), do: "string"

  defp result(conn, id, result) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp error(conn, id, code, message) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason({:invalid_graph, errors}), do: Enum.join(List.wrap(errors), "; ")
  defp format_reason(reason), do: inspect(reason)
end
