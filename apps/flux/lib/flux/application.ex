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
      {Registry, keys: :unique, name: Flux.GenerationRegistry},
      {Task.Supervisor, name: Flux.GenerationSupervisor},
      Flux.StreamBuffers,
      Flux.LLMCache,
      Flux.ProviderHealth,
      {Oban, Application.fetch_env!(:flux, Oban)}
    ]

    # FLUX_VECTOR_DIMS: type the pgvector column and build the HNSW
    # index once the Repo is up (best-effort; exact scan otherwise).
    children =
      case Application.get_env(:flux, :vector_dims) do
        dims when is_integer(dims) and dims > 0 ->
          children ++
            [
              Supervisor.child_spec(
                # Runtime-resolved: flux must not compile-depend on flux_rag.
                {Task, fn -> apply(Flux.RAG.VectorStore.PgVector, :ensure_hnsw, [dims]) end},
                id: :pgvector_hnsw,
                restart: :temporary
              )
            ]

        _unset ->
          children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Flux.Supervisor)
  end
end
