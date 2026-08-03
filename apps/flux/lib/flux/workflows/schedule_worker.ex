defmodule Flux.Workflows.ScheduleWorker do
  @moduledoc """
  Minute tick (Oban cron): starts published runs for every enabled schedule
  trigger that is due — either its interval elapsed, or its cron expression
  (parsed with Oban's own parser) matches the current minute. Also polls
  due `:plugin` triggers; every event a trigger plugin returns becomes
  one run with the event merged into the start inputs.
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

    Flux.Evals.run_scheduled(now)
    Workflows.run_scheduled_batches(now)
    Flux.Export.run_scheduled(now)

    plugin_due =
      from(t in Trigger,
        where: t.enabled and t.type == :plugin and not is_nil(t.plugin_id),
        where:
          is_nil(t.last_run_at) or
            t.last_run_at <= datetime_add(^now, fragment("-?", t.interval_minutes), "minute")
      )
      |> Repo.all(skip_workspace_guard: true)

    Enum.each(plugin_due, &poll_plugin_trigger(&1, now))

    :ok
  end

  # For :plugin triggers `last_run_at` records the last poll (successful or
  # not) so a quiet or failing source doesn't get hot-polled every minute.
  defp poll_plugin_trigger(trigger, now) do
    credentials =
      case Flux.Providers.fetch_config(trigger.workspace_id, trigger.plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    case plugin_runtime().poll_trigger_plugin(
           trigger.plugin_id,
           credentials,
           trigger.plugin_cursor
         ) do
      {:ok, events, cursor} ->
        trigger
        |> Ecto.Changeset.change(plugin_cursor: cursor, last_run_at: now)
        |> Repo.update()

        for event <- events, is_map(event) do
          case Workflows.run_from_trigger(trigger, event) do
            {:ok, _run} -> :ok
            {:error, _reason} -> :ok
          end
        end

      {:error, _reason} ->
        trigger |> Ecto.Changeset.change(last_run_at: now) |> Repo.update()
    end
  end

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

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
