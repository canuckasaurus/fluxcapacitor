defmodule Flux.LLMCache do
  @moduledoc """
  Exact-request LLM response cache: identical `{workspace, provider,
  model, messages, params, tools}` requests within the workspace's TTL
  return the stored reply without touching the provider — repeated batch
  and eval runs stop paying for the same completions twice.

  Off by default; workspaces opt in with a TTL (minutes) in settings.
  Cache hits replay the content as a single chunk and report zero token
  usage (nothing was billed), tagged `"cached" => true`. Storage is one
  public ETS table owned by this GenServer; entries expire lazily.
  """

  use GenServer

  @table :flux_llm_cache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Cache key for a request (workspace-scoped, order-stable)."
  def key(workspace_id, request) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        workspace_id,
        request.provider_plugin_id,
        request.model,
        request.messages,
        request[:params] || %{},
        Map.get(request, :tools, [])
      })
    )
  end

  def get(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, response, expires_at}] when expires_at > now ->
        bump(:hits)
        {:ok, response}

      [{^key, _response, _expired}] ->
        :ets.delete(@table, key)
        bump(:misses)
        :miss

      [] ->
        bump(:misses)
        :miss
    end
  end

  def put(key, response, ttl_minutes) when is_integer(ttl_minutes) and ttl_minutes > 0 do
    expires_at = System.system_time(:second) + ttl_minutes * 60
    :ets.insert(@table, {key, response, expires_at})
    :ok
  end

  @doc """
  Since-boot cache effectiveness: hits, misses, hit rate (percent), and
  how many entries currently sit in the table.
  """
  def stats do
    hits = counter(:hits)
    misses = counter(:misses)
    lookups = hits + misses

    %{
      hits: hits,
      misses: misses,
      hit_rate: (lookups > 0 && Float.round(hits / lookups * 100, 1)) || 0.0,
      entries: max(:ets.info(@table, :size) - 2, 0)
    }
  end

  defp bump(kind), do: :ets.update_counter(@table, {:counter, kind}, 1, {{:counter, kind}, 0})

  defp counter(kind) do
    case :ets.lookup(@table, {:counter, kind}) do
      [{{:counter, ^kind}, count}] -> count
      [] -> 0
    end
  end

  @doc false
  def purge, do: :ets.delete_all_objects(@table)
end
