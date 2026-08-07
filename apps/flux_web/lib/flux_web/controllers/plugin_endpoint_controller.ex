defmodule FluxWeb.PluginEndpointController do
  @moduledoc """
  Serves endpoint plugins at `/e/:token/*path`. The token identifies one
  workspace installation; the plugin receives the request (with the
  workspace's decrypted credentials) and returns the complete response.
  """
  use FluxWeb, :controller

  @per_token_per_minute 120
  @max_response_bytes 1_000_000

  def handle(conn, %{"token" => token} = params) do
    with {:allow, _count} <-
           FluxWeb.RateLimit.hit("plugin-endpoint:#{token}", 60_000, @per_token_per_minute),
         {:ok, %{workspace_id: workspace_id, plugin_id: plugin_id}} <-
           Flux.Tools.installation_by_endpoint_token(token),
         {:ok, response} <-
           plugin_runtime().handle_endpoint(plugin_id, credentials(workspace_id, plugin_id), %{
             method: conn.method,
             path: Enum.join(params["path"] || [], "/"),
             query: conn.query_params,
             body: conn.body_params
           }),
         :ok <- check_response_size(response) do
      conn
      |> put_resp_content_type(safe_content_type(response[:content_type]))
      |> send_resp(response[:status] || 200, response[:body] || "")
    else
      {:deny, _limit} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> send_error(429, "rate limit exceeded for this endpoint")

      {:error, :not_found} ->
        send_error(conn, 404, "unknown endpoint token")

      {:error, :not_supported} ->
        send_error(conn, 404, "this plugin serves no endpoints")

      {:error, :unknown_plugin} ->
        send_error(conn, 404, "this plugin is no longer available")

      {:error, :response_too_large} ->
        send_error(conn, 502, "the plugin response exceeded #{@max_response_bytes} bytes")

      {:error, reason} ->
        send_error(conn, 502, format_reason(reason))
    end
  end

  # Sobelow flagged the plugin-chosen content type (XSS.ContentType):
  # text/html here would let a compromised plugin script under the app
  # origin. Allowlist non-active types; anything else serves as data.
  @allowed_content_types ~w(application/json text/plain text/csv text/calendar
                            application/xml text/xml application/rss+xml)

  defp safe_content_type(content_type) do
    base = content_type |> to_string() |> String.split(";") |> hd() |> String.trim()

    if base in @allowed_content_types do
      base
    else
      "application/json"
    end
  end

  defp check_response_size(response) do
    body = response[:body] || ""

    if is_binary(body) and byte_size(body) <= @max_response_bytes do
      :ok
    else
      {:error, :response_too_large}
    end
  end

  defp credentials(workspace_id, plugin_id) do
    case Flux.Providers.fetch_config(workspace_id, plugin_id) do
      {:ok, config} -> config
      {:error, :not_configured} -> %{}
    end
  end

  # Non-binary bodies (a plugin returning a map) also land here.
  defp send_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => message}))
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)
end
