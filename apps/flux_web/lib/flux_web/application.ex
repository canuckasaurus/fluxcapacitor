defmodule FluxWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Trace instrumentation is always attached; whether spans go anywhere
    # is decided by the exporter config (:none unless OTLP is configured).
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:flux, :repo])

    children = [
      FluxWeb.Telemetry,
      FluxWeb.PromEx,
      {FluxWeb.RateLimit, clean_period: :timer.minutes(1)},
      # Start to serve requests, typically the last entry
      FluxWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FluxWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FluxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
