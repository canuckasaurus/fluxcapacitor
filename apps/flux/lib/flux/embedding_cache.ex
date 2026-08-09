defmodule Flux.EmbeddingCache do
  @moduledoc """
  Per-text embedding cache: embeddings are deterministic, so identical
  `{plugin, model, text}` triples within the TTL reuse the stored
  vector — re-indexing and repeated retrievals stop paying twice.
  Always on (24h TTL); partial hits work, only misses reach the
  provider. One public ETS table, same shape as `Flux.LLMCache`.
  """

  use GenServer

  @table :flux_embedding_cache
  @ttl_seconds 24 * 3600

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  def key(plugin_id, model, text) do
    :crypto.hash(:sha256, :erlang.term_to_binary({plugin_id, model, text}))
  end

  def get(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, vector, expires_at}] when expires_at > now ->
        bump(:hits)
        {:ok, vector}

      [{^key, _vector, _expired}] ->
        :ets.delete(@table, key)
        bump(:misses)
        :miss

      [] ->
        bump(:misses)
        :miss
    end
  end

  def put(key, vector) do
    :ets.insert(@table, {key, vector, System.system_time(:second) + @ttl_seconds})
    :ok
  end

  @doc "Since-boot hits, misses, hit rate, and live entry count."
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
end
