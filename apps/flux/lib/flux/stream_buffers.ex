defmodule Flux.StreamBuffers do
  @moduledoc """
  Public ETS buffer of in-flight streamed content, keyed by message/run id.

  Producer callbacks run inside plugin-runtime tasks (not the process that
  started the generation), so a process-owned accumulator can't be read
  when a stop kills the pipeline; this table can. Single writer per key.
  """
  use GenServer

  @table :flux_stream_buffers

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Appends a delta to the buffer for `id`."
  def append(id, delta) do
    case :ets.lookup(@table, id) do
      [{^id, accumulated}] -> :ets.insert(@table, {id, accumulated <> delta})
      [] -> :ets.insert(@table, {id, delta})
    end

    :ok
  end

  @doc "The content streamed so far for `id` (\"\" when none)."
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, accumulated}] -> accumulated
      [] -> ""
    end
  end

  def delete(id) do
    :ets.delete(@table, id)
    :ok
  end
end
