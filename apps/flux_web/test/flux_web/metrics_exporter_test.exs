defmodule FluxWeb.MetricsExporterTest do
  use FluxWeb.ConnCase, async: false

  test "GET /metrics serves Prometheus text when enabled", %{conn: conn} do
    body = conn |> get("/metrics") |> response(200)
    assert body =~ "beam"
  end

  test "GET /metrics 404s when disabled", %{conn: conn} do
    Application.put_env(:flux_web, :metrics_enabled, false)
    on_exit(fn -> Application.put_env(:flux_web, :metrics_enabled, true) end)

    assert conn |> get("/metrics") |> response(404)
  end
end
