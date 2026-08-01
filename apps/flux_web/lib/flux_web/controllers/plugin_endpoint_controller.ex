defmodule FluxWeb.PluginEndpointController do
  @moduledoc """
  Serves endpoint plugins at `/e/:token/*path`. The token identifies one
  workspace installation; the plugin receives the request (with the
  workspace's decrypted credentials) and returns the complete response.
  """
  use FluxWeb, :controller

  def handle(conn, %{"token" => token} = params) do
    with {:ok, %{workspace_id: workspace_id, plugin_id: plugin_id}} <-
           Flux.Tools.installation_by_endpoint_token(token),
         {:ok, response} <-
           plugin_runtime().handle_endpoint(plugin_id, credentials(workspace_id, plugin_id), %{
             method: conn.method,
             path: Enum.join(params["path"] || [], "/"),
             query: conn.query_params,
             body: conn.body_params
           }) do
      conn
      |> put_resp_content_type(response[:content_type] || "application/json")
      |> send_resp(response[:status] || 200, response[:body] || "")
    else
      {:error, :not_found} ->
        send_error(conn, 404, "unknown endpoint token")

      {:error, :not_supported} ->
        send_error(conn, 404, "this plugin serves no endpoints")

      {:error, :unknown_plugin} ->
        send_error(conn, 404, "this plugin is no longer available")

      {:error, reason} ->
        send_error(conn, 502, format_reason(reason))
    end
  end

  defp credentials(workspace_id, plugin_id) do
    case Flux.Providers.fetch_config(workspace_id, plugin_id) do
      {:ok, config} -> config
      {:error, :not_configured} -> %{}
    end
  end

  defp send_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => message}))
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)
end
