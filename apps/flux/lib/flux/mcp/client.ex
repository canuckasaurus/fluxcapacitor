defmodule Flux.MCP.Client do
  @moduledoc """
  Minimal Model Context Protocol client over Streamable HTTP: JSON-RPC
  2.0 POSTed to the server URL. Handles both plain-JSON and SSE-framed
  responses, and echoes the server's `mcp-session-id` once issued.

  Only the tool surface is spoken: `initialize` →
  `notifications/initialized` → `tools/list` / `tools/call`.
  """

  @protocol_version "2025-03-26"
  @receive_timeout :timer.seconds(60)

  @doc "Initializes and lists the server's tools: `{:ok, [tool_map]}`."
  def list_tools(url, headers \\ %{}) do
    with {:ok, session} <- handshake(url, headers),
         {:ok, %{"tools" => tools}} <- rpc(url, headers, session, "tools/list", %{}) do
      {:ok, tools}
    else
      {:ok, other} -> {:error, "unexpected tools/list result: #{inspect(other)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Calls one tool. Returns `{:ok, %{text: ..., data: result}}` — text is
  the concatenated text content blocks, data the raw MCP result.
  """
  def call_tool(url, headers \\ %{}, name, arguments) when is_map(arguments) do
    with {:ok, session} <- handshake(url, headers),
         {:ok, result} <-
           rpc(url, headers, session, "tools/call", %{
             "name" => name,
             "arguments" => arguments
           }) do
      if result["isError"] do
        {:error, "tool error: " <> content_text(result)}
      else
        {:ok, %{text: content_text(result), data: result}}
      end
    end
  end

  defp content_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp content_text(result), do: Jason.encode!(result)

  # initialize → capture the session id → notifications/initialized.
  defp handshake(url, headers) do
    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "fluxcapacitor", "version" => "0.4.0"}
    }

    case post(url, headers, nil, envelope("initialize", params, 1)) do
      {:ok, response, session} ->
        with {:ok, _result} <- unwrap(response) do
          # Fire-and-forget per spec; servers may 202 with no body.
          post(url, headers, session, %{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized"
          })

          {:ok, session}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rpc(url, headers, session, method, params) do
    case post(url, headers, session, envelope(method, params, 2)) do
      {:ok, response, _session} -> unwrap(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp envelope(method, params, id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp post(url, headers, session, payload) do
    request_headers =
      headers
      |> Map.put("accept", "application/json, text/event-stream")
      |> then(fn h -> (session && Map.put(h, "mcp-session-id", session)) || h end)

    options =
      [
        method: :post,
        url: url,
        json: payload,
        headers: Map.to_list(request_headers),
        receive_timeout: @receive_timeout,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:flux, :mcp_req_options, []))

    with :ok <- Flux.SSRF.verify_url(url) do
      case Req.request(options) do
        {:ok, %{status: status} = response} when status in [200, 202] ->
          session = response_session(response) || session
          {:ok, decode_body(response), session}

        {:ok, %{status: status}} ->
          {:error, "MCP server answered HTTP #{status}"}

        {:error, reason} ->
          {:error, "MCP request failed: #{inspect(reason)}"}
      end
    end
  end

  defp response_session(%{headers: headers}) do
    case Map.get(headers, "mcp-session-id") do
      [session | _rest] -> session
      _absent -> nil
    end
  end

  # 202 notifications have no body; SSE bodies carry the JSON in data:
  # lines (the last data payload wins — servers may send pings first).
  defp decode_body(%{body: body}) when is_map(body), do: body

  defp decode_body(%{body: body}) when is_binary(body) do
    if String.contains?(body, "data:") do
      body
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim(String.replace_prefix(&1, "data:", "")))
      |> Enum.reduce(%{}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{} = decoded} -> decoded
          _not_json -> acc
        end
      end)
    else
      case Jason.decode(body) do
        {:ok, %{} = decoded} -> decoded
        _empty_or_invalid -> %{}
      end
    end
  end

  defp decode_body(_response), do: %{}

  defp unwrap(%{"result" => result}), do: {:ok, result}

  defp unwrap(%{"error" => %{"message" => message} = error}),
    do: {:error, "MCP error #{error["code"]}: #{message}"}

  defp unwrap(other), do: {:error, "unexpected MCP response: #{inspect(other)}"}
end
