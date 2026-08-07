defmodule Flux.Jobs do
  @moduledoc """
  Instance-level Oban visibility for the admin panel: queue depths by
  state, the jobs that need attention (retryable/discarded) with their
  last error, and retry/discard actions.
  """

  import Ecto.Query

  alias Flux.Repo

  @doc "Job counts per queue and state, alphabetical by queue."
  def queue_stats do
    Oban.Job
    |> group_by([j], [j.queue, j.state])
    |> select([j], {j.queue, j.state, count(j.id)})
    |> Repo.all()
    |> Enum.group_by(fn {queue, _state, _count} -> queue end)
    |> Enum.map(fn {queue, rows} ->
      states = Map.new(rows, fn {_queue, state, count} -> {state, count} end)

      %{
        queue: queue,
        available: Map.get(states, "available", 0),
        executing: Map.get(states, "executing", 0),
        scheduled: Map.get(states, "scheduled", 0),
        retryable: Map.get(states, "retryable", 0),
        discarded: Map.get(states, "discarded", 0),
        completed: Map.get(states, "completed", 0)
      }
    end)
    |> Enum.sort_by(& &1.queue)
  end

  @doc "Retryable and discarded jobs, newest first, with their last error."
  def problem_jobs(limit \\ 30) do
    Oban.Job
    |> where([j], j.state in ["retryable", "discarded"])
    |> order_by([j], desc: j.attempted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn job ->
      %{
        id: job.id,
        state: job.state,
        queue: job.queue,
        worker: job.worker,
        attempt: job.attempt,
        max_attempts: job.max_attempts,
        attempted_at: job.attempted_at,
        last_error: last_error(job)
      }
    end)
  end

  @doc "Queues a retryable or discarded job to run again."
  def retry_job(job_id) do
    :ok = Oban.retry_job(job_id)
    :ok
  end

  @doc "Cancels a job — retryable ones stop retrying."
  def discard_job(job_id) do
    :ok = Oban.cancel_job(job_id)
    :ok
  end

  defp last_error(%Oban.Job{errors: [_ | _] = errors}) do
    errors
    |> List.last()
    |> Map.get("error", "")
    |> String.slice(0, 300)
  end

  defp last_error(_job), do: nil
end
