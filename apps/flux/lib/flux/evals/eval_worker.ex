defmodule Flux.Evals.EvalWorker do
  @moduledoc """
  Runs and grades one eval pass. Single attempt — cases bill tokens, so
  a crashed pass stays incomplete rather than re-running.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"eval_run_id" => eval_run_id}}) do
    Flux.Evals.perform_eval(eval_run_id)
  end
end
