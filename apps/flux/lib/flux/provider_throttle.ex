defmodule Flux.ProviderThrottle do
  @moduledoc """
  Fixed-window per-minute call counters in ETS, enforcing the optional
  per-provider rate caps — so a low-tier key or a self-hosted endpoint
  can't be stampeded by parallel branches and batches. In-memory by
  design: a restart forgives the current minute, which is the right
  failure mode for a protective cap.
  """
  use GenServer

  @table :flux_provider_throttle

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, []}
  end

  @doc """
  Counts one call against `{workspace_id, plugin_id}` and answers
  whether it fits under `cap` calls in the current minute. A nil cap
  always allows. Safe before boot (allows when the table is missing).
  """
  def allow?(_workspace_id, _plugin_id, nil), do: true

  def allow?(workspace_id, plugin_id, cap) when is_integer(cap) and cap > 0 do
    minute = div(System.system_time(:second), 60)
    key = {workspace_id, plugin_id, minute}

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    # Drop the previous minute's key opportunistically.
    :ets.delete(@table, {workspace_id, plugin_id, minute - 1})

    count <= cap
  rescue
    ArgumentError -> true
  end
end
