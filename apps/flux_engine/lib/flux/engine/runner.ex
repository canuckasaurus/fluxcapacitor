defmodule Flux.Engine.Runner do
  @moduledoc """
  Synchronous walk of a validated graph in the calling process.

  The embedding application owns process placement (supervised task,
  registry, kill-to-stop) and event delivery; the runner just executes
  nodes, threads the variable pool, and emits events through the host.
  """

  alias Flux.Engine.{Graph, Host, Node}

  # Acyclic graphs terminate on their own; this guards a runaway regression.
  @max_steps 200

  @type success :: %{outputs: map(), node_executions: [map()], elapsed_ms: non_neg_integer()}
  @type failure :: %{
          error: String.t(),
          node_id: String.t() | nil,
          node_executions: [map()],
          elapsed_ms: non_neg_integer()
        }

  @spec run(Graph.t(), map(), Host.t()) :: {:ok, success()} | {:error, failure()}
  def run(%Graph{} = graph, inputs, %Host{} = host) when is_map(inputs) do
    started_at = System.monotonic_time(:millisecond)
    Host.emit(host, {:workflow_started, %{inputs: inputs}})

    start = Map.fetch!(graph.nodes, graph.start_id)
    start = %{start | config: Map.put(start.config, "__inputs__", inputs)}

    case walk(graph, start, %{}, host, [], @max_steps) do
      {:ok, outputs, executions} ->
        {:ok,
         %{
           outputs: outputs,
           node_executions: Enum.reverse(executions),
           elapsed_ms: elapsed(started_at)
         }}

      {:error, node_id, reason, executions} ->
        {:error,
         %{
           error: format_error(reason),
           node_id: node_id,
           node_executions: Enum.reverse(executions),
           elapsed_ms: elapsed(started_at)
         }}
    end
  end

  defp walk(_graph, node, _pool, _host, executions, 0),
    do: {:error, node.id, "the run exceeded #{@max_steps} steps", executions}

  defp walk(graph, node, pool, host, executions, steps_left) do
    Host.emit(host, {:node_started, %{node_id: node.id, node_type: node.type, title: node.title}})
    node_started_at = System.monotonic_time(:millisecond)

    case safe_run(node, pool, host) do
      {:ok, outputs, branch} ->
        node_elapsed = elapsed(node_started_at)
        pool = Map.put(pool, node.id, outputs)

        Host.emit(
          host,
          {:node_finished, %{node_id: node.id, outputs: outputs, elapsed_ms: node_elapsed}}
        )

        executions = [execution(node, "succeeded", outputs, nil, node_elapsed) | executions]

        case Graph.next_edge(graph, node.id, branch) do
          nil ->
            {:ok, outputs, executions}

          edge ->
            next = Map.fetch!(graph.nodes, edge.target)
            walk(graph, next, pool, host, executions, steps_left - 1)
        end

      {:error, reason} ->
        node_elapsed = elapsed(node_started_at)
        error = format_error(reason)
        Host.emit(host, {:node_failed, %{node_id: node.id, error: error}})
        executions = [execution(node, "failed", %{}, error, node_elapsed) | executions]
        {:error, node.id, reason, executions}
    end
  end

  defp safe_run(node, pool, host) do
    case Node.implementation(node.type).run(node, pool, host) do
      {:ok, outputs} -> {:ok, outputs, "default"}
      {:ok, outputs, branch} -> {:ok, outputs, branch}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp execution(node, status, outputs, error, elapsed_ms) do
    %{
      "node_id" => node.id,
      "node_type" => node.type,
      "title" => node.title,
      "status" => status,
      "outputs" => outputs,
      "error" => error,
      "elapsed_ms" => elapsed_ms
    }
  end

  defp elapsed(from), do: max(System.monotonic_time(:millisecond) - from, 0)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error({:invalid_credentials, message}) when is_binary(message), do: message
  defp format_error({:http_error, status, _body}), do: "Provider returned HTTP #{status}."
  defp format_error(:timeout), do: "The model did not respond in time."
  defp format_error(reason), do: inspect(reason)
end
