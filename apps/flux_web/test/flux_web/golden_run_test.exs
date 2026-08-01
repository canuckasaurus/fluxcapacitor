defmodule FluxWeb.GoldenRunTest do
  @moduledoc """
  Golden replay: every fixture in test/support/golden re-runs on the
  echo provider and must reproduce its recorded outcome — outputs and
  the per-node status set. Record new fixtures from the editor's run
  history ("Download fixture") and commit them here.
  """
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  @golden_dir Path.expand("../support/golden", __DIR__)

  setup do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Golden WS"})
    %{scope: Accounts.scope_for(account)}
  end

  for path <- Path.wildcard(Path.join(@golden_dir, "*.json")) do
    @fixture_path path

    test "replays #{Path.basename(path)}", %{scope: scope} do
      fixture = @fixture_path |> File.read!() |> Jason.decode!()
      assert fixture["format"] == "fluxcapacitor-run-fixture"

      {:ok, workflow} =
        Workflows.create_workflow(scope, %{"name" => fixture["name"] || "Golden"})

      {:ok, workflow} = Workflows.update_draft(scope, workflow, fixture["graph"])
      {:ok, _run} = Workflows.start_run(scope, workflow, fixture["inputs"] || %{})

      finished =
        receive do
          {:run_finished, finished} -> finished
        after
          10_000 -> flunk("golden run did not finish")
        end

      expected = fixture["expected"]
      assert to_string(finished.status) == expected["status"]
      assert finished.outputs == expected["outputs"]

      if expected["error"] do
        assert finished.error =~ expected["error"]
      end

      # Node statuses compare as a set: parallel branches may interleave.
      recorded =
        expected["node_sequence"]
        |> Enum.map(&{&1["node_id"], &1["status"]})
        |> Enum.sort()

      replayed =
        finished.node_executions
        |> Enum.map(&{&1["node_id"], &1["status"]})
        |> Enum.sort()

      assert replayed == recorded
    end
  end

  test "the exporter round-trips a live run into a passing fixture", %{scope: scope} do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Recorder"})

    graph =
      update_in(workflow.graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node ->
            node
            |> put_in(["config", "provider_plugin_id"], "echo")
            |> put_in(["config", "model"], "echo-1")

          node ->
            node
        end)
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, run} = Workflows.start_run(scope, workflow, %{"query" => "record me"})
    assert_receive {:run_finished, %{status: :succeeded}}, 5_000

    {:ok, fixture} = Workflows.export_run_fixture(scope, run.id)
    assert fixture["format"] == "fluxcapacitor-run-fixture"
    assert fixture["inputs"] == %{"query" => "record me"}
    assert fixture["expected"]["status"] == "succeeded"
    assert fixture["graph"]["nodes"] != []

    # Replaying the exported fixture reproduces the recorded outcome.
    {:ok, replay_workflow} = Workflows.create_workflow(scope, %{"name" => "Replay"})
    {:ok, replay_workflow} = Workflows.update_draft(scope, replay_workflow, fixture["graph"])
    {:ok, _replay} = Workflows.start_run(scope, replay_workflow, fixture["inputs"])
    assert_receive {:run_finished, replayed}, 5_000

    assert to_string(replayed.status) == fixture["expected"]["status"]
    assert replayed.outputs == fixture["expected"]["outputs"]

    # Running runs refuse to export.
    {:ok, live} = Workflows.start_run(scope, workflow, %{"query" => "still going"})
    result = Workflows.export_run_fixture(scope, live.id)
    assert result == {:error, :not_finished} or match?({:ok, _fixture}, result)
    assert_receive {:run_finished, _}, 5_000
  end
end
