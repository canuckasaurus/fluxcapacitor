defmodule FluxWeb.MetricsExporter do
  @moduledoc """
  Serves Prometheus metrics at `GET /metrics` when
  `config :flux_web, :metrics_enabled` is true (set via `FLUX_METRICS=1`
  in production; on by default in dev/test). 404s otherwise so the
  endpoint reveals nothing when disabled.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: PromEx.Plug.init(Keyword.put(opts, :prom_ex_module, FluxWeb.PromEx))

  @impl Plug
  def call(%Plug.Conn{request_path: "/metrics"} = conn, opts) do
    if Application.get_env(:flux_web, :metrics_enabled, false) do
      PromEx.Plug.call(conn, opts)
    else
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    end
  end

  def call(conn, _opts), do: conn
end
