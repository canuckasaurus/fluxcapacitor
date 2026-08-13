defmodule Flux.Batch28Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch28 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace}
  end

  describe "serving pin" do
    test "a pin freezes serving; unpin returns to latest", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Pin Flux"})
      {:ok, v1} = Workflows.publish(scope, workflow)
      {:ok, _v2} = Workflows.publish(scope, workflow)

      assert Workflows.serving_version(scope, workflow).version == 2

      assert {:error, :version_not_found} = Workflows.set_serving_pin(scope, workflow, 99)

      {:ok, workflow} = Workflows.set_serving_pin(scope, workflow, v1.version)
      assert Workflows.serving_version(scope, workflow).version == 1

      # New publishes do not move a pinned serving version.
      {:ok, _v3} = Workflows.publish(scope, workflow)
      assert Workflows.serving_version(scope, workflow).version == 1

      {:ok, workflow} = Workflows.set_serving_pin(scope, workflow, nil)
      assert Workflows.serving_version(scope, workflow).version == 3
    end
  end

  describe "paused-run reminders" do
    test "runs paused over 24h notify once per workspace", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Paused Flux"})

      # Backdate relative to the FAKE 08:30 clock the check runs on —
      # anchoring to the real clock makes this fail after 14:30 UTC.
      now = DateTime.utc_now(:second) |> Map.merge(%{hour: 8, minute: 30})
      stale = DateTime.add(now, -30, :hour)

      for _n <- 1..2 do
        Flux.Repo.insert!(%Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :paused,
          inserted_at: stale,
          updated_at: stale
        })
      end

      assert :ok = Workflows.check_paused_runs(now)

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      assert Enum.any?(titles, &(&1 =~ "2 runs have been paused"))
    end
  end

  describe "watchdog mute" do
    test "a muted stalled trigger stays quiet", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Muted Flux"})

      {:ok, trigger} =
        Workflows.create_trigger(scope, workflow, %{
          "type" => "schedule",
          "interval_minutes" => 30
        })

      {:ok, trigger} = Workflows.set_trigger_watchdog_muted(scope, trigger.id, true)
      assert trigger.watchdog_muted

      trigger
      |> Ecto.Changeset.change(
        last_run_at: DateTime.utc_now(:second) |> DateTime.add(-600, :minute)
      )
      |> Flux.Repo.update!()

      now = DateTime.utc_now(:second) |> Map.merge(%{hour: 8, minute: 20})
      assert :ok = Workflows.check_schedule_watchdog(now)

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      refute Enum.any?(titles, &(&1 =~ "Schedule watchdog"))
    end
  end

  describe "latency percentiles" do
    test "p50/p95 over the recent runs", %{scope: scope, workspace: workspace} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Latency Flux"})

      for ms <- [100, 200, 300, 400, 10_000] do
        Flux.Repo.insert!(%Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :succeeded,
          elapsed_ms: ms
        })
      end

      stats = Workflows.latency_stats(scope, workflow.id)
      assert stats.count == 5
      assert stats.p50_ms == 300
      assert stats.p95_ms == 10_000

      assert Workflows.latency_stats(scope, Ecto.UUID.generate()) == nil
    end
  end

  describe "visitor forget" do
    test "removes conversations, messages, and uploads for one ref", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Forget App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "forget-me"})
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "remember this")
      assert_receive {:done, _reply}, 5_000

      keeper = Chat.create_conversation(scope, app, %{end_user_ref: "keep-me"})
      {:ok, _user, _assistant} = Chat.send_message(scope, app, keeper, "keep this")
      assert_receive {:done, _reply}, 5_000

      assert {:ok, 1} = Chat.forget_visitor(scope, app, "forget-me")

      assert Chat.visitor_conversations(scope, app.id, "forget-me") == []
      assert length(Chat.visitor_conversations(scope, app.id, "keep-me")) == 1

      # The audit trail records the erasure.
      assert Flux.Repo.exists?(
               from(a in Flux.Audit.Entry, where: a.action == "visitor.forget"),
               skip_workspace_guard: true
             )
    end
  end
end
