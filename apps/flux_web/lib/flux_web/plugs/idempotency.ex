defmodule FluxWeb.Plugs.Idempotency do
  @moduledoc """
  `Idempotency-Key` support for `/v1` POSTs (mounted after ServiceAuth):
  a key seen before replays the stored response with
  `idempotency-replayed: true`; otherwise the response is recorded on
  the way out — but only buffered 2xx JSON bodies, because an SSE
  stream can't be replayed and a failure shouldn't be pinned.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    with [key] when key != "" <- get_req_header(conn, "idempotency-key"),
         %{workspace: %{id: workspace_id}} <- conn.assigns[:service_scope] do
      case Flux.Idempotency.lookup(workspace_id, key) do
        nil ->
          record_on_send(conn, workspace_id, key)

        stored ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("idempotency-replayed", "true")
          |> send_resp(stored.response_status, stored.response_body)
          |> halt()
      end
    else
      _no_key_or_auth -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp record_on_send(conn, workspace_id, key) do
    register_before_send(conn, fn conn ->
      # Buffered responses arrive as iodata; chunked (SSE) ones as nil.
      body = conn.resp_body && IO.iodata_to_binary(conn.resp_body)

      if conn.status in 200..299 and is_binary(body) and body != "" do
        Flux.Idempotency.record(workspace_id, key, conn.status, body)
      end

      conn
    end)
  end
end
