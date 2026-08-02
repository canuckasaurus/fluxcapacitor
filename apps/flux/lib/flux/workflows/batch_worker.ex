defmodule Flux.Workflows.BatchWorker do
  @moduledoc """
  Executes a workflow batch row by row. Single attempt — rows are not
  idempotent, so a crashed batch stays partially complete rather than
  re-running rows that already billed tokens.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
    Flux.Workflows.perform_batch(batch_id)
  end
end
