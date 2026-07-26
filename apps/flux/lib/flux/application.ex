defmodule Flux.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Flux.Repo,
      Flux.Vault,
      {Cachex, [:flux_cache]},
      {DNSCluster, query: Application.get_env(:flux, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Flux.PubSub},
      {Oban, Application.fetch_env!(:flux, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Flux.Supervisor)
  end
end
