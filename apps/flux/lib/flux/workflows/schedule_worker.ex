defmodule Flux.Workflows.ScheduleWorker do
  @moduledoc """
  Minute tick (Oban cron): starts published runs for every enabled schedule
  trigger that is due — either its interval elapsed, or its cron expression
  (parsed with Oban's own parser) matches the current minute.
  """
  use Oban.Worker, queue: :triggers, max_attempts: 1

  import Ecto.Query

  alias Flux.Repo
  alias Flux.Workflows
  alias Flux.Workflows.Trigger

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now(:second)

    interval_due =
      from(t in Trigger,
        where: t.enabled and t.type == :schedule,
        where: is_nil(t.cron) and not is_nil(t.interval_minutes),
        where:
          is_nil(t.last_run_at) or
            t.last_run_at <= datetime_add(^now, fragment("-?", t.interval_minutes), "minute")
      )
      |> Repo.all(skip_workspace_guard: true)

    cron_due =
      from(t in Trigger,
        where: t.enabled and t.type == :schedule and not is_nil(t.cron)
      )
      |> Repo.all(skip_workspace_guard: true)
      |> Enum.filter(&cron_due?(&1, now))

    for trigger <- interval_due ++ cron_due do
      case Workflows.run_from_trigger(trigger) do
        {:ok, _run} -> :ok
        {:error, _reason} -> :ok
      end
    end

    :ok
  end

  # Fires when the expression matches the current minute, at most once per
  # minute (last_run_at guard covers tick jitter and retries).
  defp cron_due?(trigger, now) do
    minute_start = %{now | second: 0}

    with {:ok, expression} <- Oban.Cron.Expression.parse(trigger.cron),
         true <- Oban.Cron.Expression.now?(expression, now) do
      trigger.last_run_at == nil or DateTime.compare(trigger.last_run_at, minute_start) == :lt
    else
      _not_due_or_invalid -> false
    end
  end
end
