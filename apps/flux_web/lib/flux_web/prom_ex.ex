defmodule FluxWeb.PromEx do
  @moduledoc """
  Prometheus metrics via PromEx: BEAM, Phoenix, LiveView, Ecto, and Oban.
  Scrape at `GET /metrics` (enabled with `FLUX_METRICS=1`; on by default
  in dev and test).
  """
  use PromEx, otp_app: :flux_web

  @impl true
  def plugins do
    [
      PromEx.Plugins.Application,
      PromEx.Plugins.Beam,
      {PromEx.Plugins.Phoenix, router: FluxWeb.Router, endpoint: FluxWeb.Endpoint},
      {PromEx.Plugins.Ecto, repos: [Flux.Repo]},
      PromEx.Plugins.Oban,
      PromEx.Plugins.PhoenixLiveView,
      FluxWeb.PromEx.FluxRuns
    ]
  end

  @impl true
  def dashboard_assigns, do: []

  @impl true
  def dashboards, do: []
end
