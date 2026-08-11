defmodule Flux.ProviderHealth do
  @moduledoc """
  Rolling per-provider call/error counters in ETS — "is it us or is it
  the provider" at a glance on the admin panel. In-memory by design:
  counts reset on restart, and that's fine for a health signal.
  """
  use GenServer

  @table :flux_provider_health

  @recent_cap 100

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, []}
  end

  @doc """
  Appends one call to the recent-calls ring (provider, model, latency,
  outcome — the last #{@recent_cap} kept). Fire-and-forget; safe before
  boot.
  """
  def log_call(provider, model, latency_ms, outcome) do
    GenServer.cast(__MODULE__, {
      :log,
      %{
        provider: to_string(provider),
        model: to_string(model || ""),
        latency_ms: latency_ms,
        outcome: outcome,
        at: DateTime.utc_now(:second)
      }
    })
  end

  @doc "The last #{@recent_cap} provider calls, newest first."
  def recent do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :recent)
    end
  end

  @impl true
  def handle_cast({:log, entry}, recent) do
    {:noreply, Enum.take([entry | recent], @recent_cap)}
  end

  @impl true
  def handle_call(:recent, _from, recent), do: {:reply, recent, recent}

  @doc "Counts one provider call outcome. Safe to call before boot."
  def record(provider, outcome) when outcome in [:ok, :error] do
    if :ets.whereis(@table) != :undefined do
      key = {to_string(provider), outcome}
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
    end

    :ok
  end

  @doc "Per-provider `%{calls, errors, error_rate}` since boot."
  def stats do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.group_by(fn {{provider, _outcome}, _n} -> provider end)
      |> Enum.map(fn {provider, rows} ->
        counts = Map.new(rows, fn {{_provider, outcome}, n} -> {outcome, n} end)
        ok = counts[:ok] || 0
        errors = counts[:error] || 0
        calls = ok + errors

        %{
          provider: provider,
          calls: calls,
          errors: errors,
          error_rate: (calls > 0 && Float.round(errors / calls * 100, 1)) || 0.0
        }
      end)
      |> Enum.sort_by(& &1.provider)
    end
  end
end
