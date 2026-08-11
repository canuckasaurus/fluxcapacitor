defmodule Flux.Batch27Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch27 WS"})
    scope = Accounts.scope_for(account)
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Watchdog Flux"})

    %{scope: scope, workspace: workspace, workflow: workflow}
  end

  describe "schedule watchdog" do
    defp watchdog_now, do: DateTime.utc_now(:second) |> Map.merge(%{hour: 8, minute: 20})

    defp backdate_trigger!(trigger, minutes_ago) do
      trigger
      |> Ecto.Changeset.change(last_run_at: watchdog_now() |> DateTime.add(-minutes_ago, :minute))
      |> Flux.Repo.update!()
    end

    test "a stalled interval trigger raises a notification", %{
      scope: scope,
      workflow: workflow
    } do
      {:ok, trigger} =
        Workflows.create_trigger(scope, workflow, %{
          "type" => "schedule",
          "interval_minutes" => 30
        })

      backdate_trigger!(trigger, 180)

      assert :ok = Workflows.check_schedule_watchdog(watchdog_now())

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      assert Enum.any?(titles, &(&1 =~ "Schedule watchdog"))
    end

    test "a healthy trigger stays quiet", %{scope: scope, workflow: workflow} do
      {:ok, trigger} =
        Workflows.create_trigger(scope, workflow, %{
          "type" => "schedule",
          "interval_minutes" => 30
        })

      backdate_trigger!(trigger, 10)

      assert :ok = Workflows.check_schedule_watchdog(watchdog_now())

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      refute Enum.any?(titles, &(&1 =~ "Schedule watchdog"))
    end

    test "hourly cron triggers estimate their period", %{scope: scope, workflow: workflow} do
      {:ok, trigger} =
        Workflows.create_trigger(scope, workflow, %{
          "type" => "schedule",
          "cron" => "0 * * * *"
        })

      backdate_trigger!(trigger, 60 * 5)

      assert :ok = Workflows.check_schedule_watchdog(watchdog_now())

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      assert Enum.any?(titles, &(&1 =~ "Schedule watchdog"))
    end
  end

  describe "provider call log" do
    test "log_call keeps a newest-first ring", %{} do
      Flux.ProviderHealth.log_call("echo", "echo-1", 42, :ok)
      Flux.ProviderHealth.log_call("echo", "echo-1", 99, :error)

      # Casts are async; a sync call flushes the mailbox.
      recent = Flux.ProviderHealth.recent()

      assert [%{latency_ms: 99, outcome: :error} | _rest] = recent
      assert Enum.any?(recent, &(&1.latency_ms == 42 and &1.outcome == :ok))
    end
  end
end
