defmodule FluxWeb.Plugs.Idempotency do
  @moduledoc """
  `Idempotency-Key` support for `/v1` POSTs (mounted after ServiceAuth):
  the key is reserved atomically before the request runs, so two
  concurrent first-requests with the same key can't both miss and both
  run the work. A key seen before replays the stored response with
  `idempotency-replayed: true`; a key still being worked on by another
  request in flight is refused with 409; a fresh reservation records
  its response on the way out — but only buffered 2xx JSON bodies,
  because an SSE stream can't be replayed and a failure shouldn't be
  pinned (its reservation is released instead, so a retry can proceed).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    with [key] when key != "" <- get_req_header(conn, "idempotency-key"),
         %{workspace: %{id: workspace_id}} <- conn.assigns[:service_scope] do
      case Flux.Idempotency.reserve(workspace_id, key) do
        {:reserved, id} ->
          record_on_send(conn, id)

        {:completed, status, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("idempotency-replayed", "true")
          |> send_resp(status, body)
          |> halt()

        :in_progress ->
          error =
            Jason.encode!(%{
              "error" => %{
                "code" => "idempotency_in_progress",
                "message" => "A request with this Idempotency-Key is already being processed"
              }
            })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(409, error)
          |> halt()
      end
    else
      _no_key_or_auth -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp record_on_send(conn, id) do
    register_before_send(conn, fn conn ->
      # Buffered responses arrive as iodata; chunked (SSE) ones as nil.
      body = conn.resp_body && IO.iodata_to_binary(conn.resp_body)

      if conn.status in 200..299 and is_binary(body) and body != "" do
        Flux.Idempotency.complete(id, conn.status, body)
      else
        Flux.Idempotency.release(id)
      end

      conn
    end)
  end
end
