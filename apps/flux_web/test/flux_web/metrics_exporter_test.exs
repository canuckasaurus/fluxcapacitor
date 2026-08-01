defmodule FluxWeb.MetricsExporterTest do
  use FluxWeb.ConnCase, async: false

  test "GET /metrics serves Prometheus text when enabled", %{conn: conn} do
    body = conn |> get("/metrics") |> response(200)
    assert body =~ "beam"
  end

  test "run telemetry lands in the flux-run metrics", %{conn: conn} do
    :telemetry.execute(
      [:flux, :workflow, :run, :finished],
      %{duration_ms: 123},
      %{status: :succeeded, source: :draft, workspace_id: Ecto.UUID.generate()}
    )

    body = conn |> get("/metrics") |> response(200)
    assert body =~ "flux_workflow_runs_total"
    assert body =~ ~s(status="succeeded")
    assert body =~ "flux_workflow_run_duration_milliseconds"
  end

  test "GET /metrics 404s when disabled", %{conn: conn} do
    Application.put_env(:flux_web, :metrics_enabled, false)
    on_exit(fn -> Application.put_env(:flux_web, :metrics_enabled, true) end)

    assert conn |> get("/metrics") |> response(404)
  end
end
