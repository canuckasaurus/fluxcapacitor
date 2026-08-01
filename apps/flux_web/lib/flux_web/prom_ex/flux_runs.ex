defmodule FluxWeb.PromEx.FluxRuns do
  @moduledoc """
  Prometheus metrics for workflow runs: totals by status/source and a
  duration histogram, from the `[:flux, :workflow, :run, :finished]`
  telemetry event.
  """
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :flux_run_event_metrics,
      [
        counter([:flux, :workflow, :runs, :total],
          event_name: [:flux, :workflow, :run, :finished],
          description: "Workflow runs finished, by status and source.",
          tags: [:status, :source],
          tag_values: fn metadata ->
            %{status: to_string(metadata.status), source: to_string(metadata.source)}
          end
        ),
        distribution([:flux, :workflow, :run, :duration, :milliseconds],
          event_name: [:flux, :workflow, :run, :finished],
          description: "Workflow run duration.",
          measurement: :duration_ms,
          tags: [:status],
          tag_values: fn metadata -> %{status: to_string(metadata.status)} end,
          reporter_options: [
            buckets: [50, 250, 1_000, 5_000, 15_000, 60_000, 300_000]
          ]
        )
      ]
    )
  end
end
