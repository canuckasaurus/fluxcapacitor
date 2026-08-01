defmodule FluxWeb.PluginTriggerTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows
  alias Flux.Workflows.ScheduleWorker

  setup do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Trig WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Feed Watcher"})

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
    {:ok, _version} = Workflows.publish(scope, workflow)

    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.TrigStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)

    stub_feed(["seed-1"])

    %{scope: scope, workflow: workflow}
  end

  defp stub_feed(guids) do
    items =
      Enum.map_join(guids, "", fn guid ->
        "<item><title>Item #{guid}</title><guid>#{guid}</guid>" <>
          "<description>Body #{guid}</description></item>"
      end)

    Req.Test.stub(Flux.TrigStub, fn conn ->
      Plug.Conn.send_resp(conn, 200, "<rss version=\"2.0\"><channel>#{items}</channel></rss>")
    end)
  end

  defp backdate!(trigger, minutes) do
    trigger
    |> Ecto.Changeset.change(
      last_run_at: DateTime.add(DateTime.utc_now(:second), -minutes, :minute)
    )
    |> Flux.Repo.update!(skip_workspace_guard: true)
  end

  defp reload!(trigger) do
    Flux.Repo.get!(Flux.Workflows.Trigger, trigger.id, skip_workspace_guard: true)
  end

  test "plugin trigger polls the source and starts one run per event", %{
    scope: scope,
    workflow: workflow
  } do
    # Requires the plugin to be installed first.
    assert {:error, :plugin_not_installed} =
             Workflows.create_trigger(scope, workflow, %{
               "type" => "plugin",
               "plugin_id" => "rss",
               "interval_minutes" => 1
             })

    :ok = Flux.Tools.install_plugin(scope, "rss")

    {:ok, _credential} =
      Flux.Providers.upsert_credential(scope, "rss", %{
        "feed_url" => "https://feeds.example.com/blog.xml"
      })

    {:ok, trigger} =
      Workflows.create_trigger(scope, workflow, %{
        "type" => "plugin",
        "plugin_id" => "rss",
        "interval_minutes" => 1,
        "inputs" => %{"query" => "from static inputs"}
      })

    # First tick primes the cursor without starting runs.
    assert :ok = ScheduleWorker.perform(%Oban.Job{args: %{}})
    trigger = reload!(trigger)
    assert trigger.plugin_cursor == "seed-1"
    assert Workflows.list_runs(scope, workflow.id) == []

    # A new item lands; the next due tick starts exactly one run.
    stub_feed(["fresh-2", "seed-1"])
    backdate!(trigger, 2)
    assert :ok = ScheduleWorker.perform(%Oban.Job{args: %{}})

    assert [run] = Workflows.list_runs(scope, workflow.id)
    assert run.inputs["title"] == "Item fresh-2"
    assert run.inputs["query"] == "from static inputs"
    assert reload!(trigger).plugin_cursor == "fresh-2"

    finished = poll_run(scope, run.id, 50)
    assert finished.status == :succeeded

    # Quiet feed on a later tick: cursor holds, no extra runs.
    backdate!(reload!(trigger), 2)
    assert :ok = ScheduleWorker.perform(%Oban.Job{args: %{}})
    assert length(Workflows.list_runs(scope, workflow.id)) == 1

    # Disabled triggers are not polled.
    Workflows.set_trigger_enabled(scope, trigger.id, false)
    stub_feed(["later-3", "fresh-2", "seed-1"])
    backdate!(reload!(trigger), 2)
    assert :ok = ScheduleWorker.perform(%Oban.Job{args: %{}})
    assert length(Workflows.list_runs(scope, workflow.id)) == 1
  end

  defp poll_run(scope, run_id, retries) do
    run = Workflows.get_run(scope, run_id)

    cond do
      run.status in [:succeeded, :failed] -> run
      retries == 0 -> run
      true -> Process.sleep(50) && poll_run(scope, run_id, retries - 1)
    end
  end
end
