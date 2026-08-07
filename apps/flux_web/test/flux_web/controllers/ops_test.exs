defmodule FluxWeb.OpsTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  test "health probes answer without auth", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health") |> json_response(200)

    ready = conn |> get(~p"/health/ready") |> json_response(200)
    assert ready["status"] == "ok"
    assert ready["checks"]["database"] == "ok"
    assert ready["checks"]["storage"] == "ok"
  end

  test "rate limiting emits quota headers when enabled" do
    Application.put_env(:flux_web, :rate_limit_enabled, true)
    on_exit(fn -> Application.put_env(:flux_web, :rate_limit_enabled, false) end)

    opts = FluxWeb.Plugs.RateLimit.init(name: "ops-test-#{System.unique_integer()}", limit: 2)

    conn =
      Phoenix.ConnTest.build_conn(:get, "/v1/parameters")
      |> Map.put(:remote_ip, {203, 0, 113, 7})

    first = FluxWeb.Plugs.RateLimit.call(conn, opts)
    assert Plug.Conn.get_resp_header(first, "x-ratelimit-limit") == ["2"]
    assert Plug.Conn.get_resp_header(first, "x-ratelimit-remaining") == ["1"]

    _second = FluxWeb.Plugs.RateLimit.call(conn, opts)
    third = FluxWeb.Plugs.RateLimit.call(conn, opts)
    assert third.status == 429
    assert Plug.Conn.get_resp_header(third, "x-ratelimit-remaining") == ["0"]
    assert [_seconds] = Plug.Conn.get_resp_header(third, "retry-after")
  end

  test "cron previews agree with Oban's parser" do
    now = DateTime.new!(~D[2026-08-07], ~T[10:30:00])

    # Daily at 06:00 → tomorrow morning.
    assert FluxWeb.CronPreview.next_fire("0 6 * * *", now) ==
             DateTime.new!(~D[2026-08-08], ~T[06:00:00])

    assert FluxWeb.CronPreview.describe("0 6 * * *", now) == "next Aug 08 06:00 UTC"

    # Every minute → the very next one; garbage → nil.
    assert FluxWeb.CronPreview.next_fire("* * * * *", now) ==
             DateTime.new!(~D[2026-08-07], ~T[10:31:00])

    assert FluxWeb.CronPreview.next_fire("not a cron", now) == nil
  end

  test "eval run results download as CSV", %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Flux.Accounts.create_workspace(account, %{name: "Ops WS"})
    scope = Flux.Accounts.scope_for(account)

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Scored"})
    {:ok, set} = Flux.Evals.create_set(scope, workflow, %{"name" => "Ops checks"})

    eval_run =
      Flux.Repo.insert!(%Flux.Evals.EvalRun{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        eval_set_id: set.id,
        target: "draft",
        graph: workflow.graph,
        grader: "contains",
        status: :completed,
        total: 2,
        passed: 1,
        failed: 1,
        avg_score: 0.5,
        results: [
          %{"expected" => "yes", "output" => "yes indeed", "score" => 1.0, "passed" => true},
          %{"expected" => "no", "output" => "maybe", "score" => 0.0, "passed" => false}
        ]
      })

    conn =
      conn
      |> log_in_account(account)
      |> get(~p"/console/fluxes/#{workflow.id}/evals/#{eval_run.id}/results")

    assert response_content_type(conn, :csv) =~ "text/csv"
    body = response(conn, 200)
    assert body =~ "expected"
    assert body =~ "yes indeed"
    assert body =~ "maybe"
  end
end
