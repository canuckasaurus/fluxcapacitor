defmodule Flux.Workflows.ScheduleWorker do
  @moduledoc """
  Minute tick (Oban cron): starts published runs for every enabled schedule
  trigger whose interval has elapsed. The first real Oban worker.
  """
  use Oban.Worker, queue: :triggers, max_attempts: 1

  import Ecto.Query

  alias Flux.Repo
  alias Flux.Workflows
  alias Flux.Workflows.Trigger

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now(:second)

    due =
      from(t in Trigger,
        where: t.enabled and t.type == :schedule and not is_nil(t.interval_minutes),
        where:
          is_nil(t.last_run_at) or
            t.last_run_at <= datetime_add(^now, fragment("-?", t.interval_minutes), "minute")
      )
      |> Repo.all(skip_workspace_guard: true)

    for trigger <- due do
      case Workflows.run_from_trigger(trigger) do
        {:ok, _run} -> :ok
        {:error, _reason} -> :ok
      end
    end

    :ok
  end
end
