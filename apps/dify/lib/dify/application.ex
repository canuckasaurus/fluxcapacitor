defmodule Dify.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Dify.Repo,
      {DNSCluster, query: Application.get_env(:dify, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dify.PubSub},
      {Oban, Application.fetch_env!(:dify, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dify.Supervisor)
  end
end
