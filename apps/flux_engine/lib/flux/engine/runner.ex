defmodule Flux.Engine.Runner do
  @moduledoc """
  Synchronous walk of a validated graph in the calling process.

  The embedding application owns process placement (supervised task,
  registry, kill-to-stop) and event delivery; the runner just executes
  nodes, threads the variable pool, and emits events through the host.

  A handle with several outgoing edges fans out into **parallel
  branches** (one task per edge). Each branch walks until it reaches a
  join — a node more than one edge points at — or the end of its path;
  when every branch arrives at the same join, the pools merge and the
  walk continues there once. Limits: branches must converge on a single
  join (or all terminate), and human-input pauses inside parallel
  branches are not supported.
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
  @type paused :: %{
          node_id: String.t(),
          prompt: map(),
          pool: map(),
          node_executions: [map()],
          elapsed_ms: non_neg_integer()
        }

  @spec run(Graph.t(), map(), Host.t(), keyword()) ::
          {:ok, success()} | {:error, failure()} | {:paused, paused()}
  def run(%Graph{} = graph, inputs, %Host{} = host, opts \\ []) when is_map(inputs) do
    started_at = System.monotonic_time(:millisecond)

    walk_result =
      case Keyword.get(opts, :resume) do
        nil ->
          Host.emit(host, {:workflow_started, %{inputs: inputs}})

          start = Map.fetch!(graph.nodes, graph.start_id)
          start = %{start | config: Map.put(start.config, "__inputs__", inputs)}

          conversation_defaults =
            Map.new(graph.conversation_variables, fn variable ->
              {variable["name"], variable["default"]}
            end)

          pool = %{
            "env" => graph.env,
            "sys" => Keyword.get(opts, :sys, %{}),
            "conversation" =>
              Map.merge(conversation_defaults, Keyword.get(opts, :conversation, %{}))
          }

          walk(graph, start, pool, host, [], @max_steps)

        # Re-run the paused node with the human's input in reach (agent
        # tool approval): the node consumes `__resume_input__` and
        # continues its own loop before the walk proceeds normally.
        %{pool: pool, node_id: node_id, input: input, rerun: true} ->
          Host.emit(host, {:workflow_resumed, %{node_id: node_id}})

          node = Map.fetch!(graph.nodes, node_id)
          node = %{node | config: Map.put(node.config, "__resume_input__", input)}
          walk(graph, node, pool, host, [], @max_steps)

        # Continue a paused run: the human's input becomes the paused
        # node's outputs, and the walk restarts on its outgoing edge.
        # Interview answers (a map) also land as one output per question.
        %{pool: pool, node_id: node_id, input: input} ->
          Host.emit(host, {:workflow_resumed, %{node_id: node_id}})

          outputs =
            case input do
              %{} = answers -> Map.put(answers, "output", answers)
              other -> %{"output" => other}
            end

          pool = Map.put(pool, node_id, outputs)
          continue(graph, node_id, "default", outputs, pool, host, [], @max_steps, :root)
      end

    case walk_result do
      {:ok, outputs, executions} ->
        {:ok,
         %{
           outputs: outputs,
           node_executions: Enum.reverse(executions),
           elapsed_ms: elapsed(started_at)
         }}

      {:paused, node_id, prompt, pool, executions} ->
        {:paused,
         %{
           node_id: node_id,
           prompt: prompt,
           pool: pool,
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

  defp walk(graph, node, pool, host, executions, steps_left, mode \\ :root, skip_join \\ false)

  defp walk(_graph, node, _pool, _host, executions, 0, _mode, _skip_join),
    do: {:error, node.id, "the run exceeded #{@max_steps} steps", executions}

  defp walk(graph, node, pool, host, executions, steps_left, mode, skip_join) do
    # Inside a parallel branch, a node with several incoming edges is the
    # join: report back instead of executing (the merge executes it once).
    if mode == :branch and not skip_join and Graph.in_degree(graph, node.id) > 1 do
      {:joined, node.id, pool, executions}
    else
      execute(graph, node, pool, host, executions, steps_left, mode)
    end
  end

  defp execute(graph, node, pool, host, executions, steps_left, mode) do
    Host.emit(host, {:node_started, %{node_id: node.id, node_type: node.type, title: node.title}})
    node_started_at = System.monotonic_time(:millisecond)

    case run_cached(node, pool, host) do
      {:pause, prompt} ->
        Host.emit(host, {:run_paused, %{node_id: node.id, prompt: prompt}})
        executions = [execution(node, "paused", %{}, nil, elapsed(node_started_at)) | executions]
        {:paused, node.id, prompt, pool, executions}

      {:ok, outputs, branch} ->
        node_elapsed = elapsed(node_started_at)
        pool = Map.put(pool, node.id, outputs)

        # Assigner writes become visible to later nodes in this run.
        pool =
          if node.type == "variable_assigner" do
            Map.update(pool, "conversation", outputs, &Map.merge(&1, outputs))
          else
            pool
          end

        Host.emit(
          host,
          {:node_finished, %{node_id: node.id, outputs: outputs, elapsed_ms: node_elapsed}}
        )

        executions = [execution(node, "succeeded", outputs, nil, node_elapsed) | executions]
        continue(graph, node.id, branch, outputs, pool, host, executions, steps_left, mode)

      {:error, reason} ->
        node_elapsed = elapsed(node_started_at)
        error = format_error(reason)
        Host.emit(host, {:node_failed, %{node_id: node.id, error: error}})
        executions = [execution(node, "failed", %{}, error, node_elapsed) | executions]

        # An "error" edge turns the failure into a routed branch: downstream
        # nodes see %{"error", "is_error"} as this node's outputs.
        case Graph.next_edges(graph, node.id, "error") do
          [] ->
            {:error, node.id, reason, executions}

          _edges ->
            outputs = %{"error" => error, "is_error" => true}
            pool = Map.put(pool, node.id, outputs)
            continue(graph, node.id, "error", outputs, pool, host, executions, steps_left, mode)
        end
    end
  end

  # Routes from a finished node: end of path, single edge, or fan-out.
  defp continue(graph, node_id, branch, outputs, pool, host, executions, steps_left, mode) do
    case Graph.next_edges(graph, node_id, branch) do
      [] ->
        {:ok, outputs, executions}

      [edge] ->
        next = Map.fetch!(graph.nodes, edge.target)
        walk(graph, next, pool, host, executions, steps_left - 1, mode, false)

      edges ->
        parallel(graph, edges, pool, host, executions, steps_left - 1, mode)
    end
  end

  # One task per edge; branches stop at the first shared join (or path
  # end), then the merged pool continues through the join exactly once.
  defp parallel(graph, edges, pool, host, executions, steps_left, mode) do
    results =
      edges
      |> Enum.map(fn edge ->
        target = Map.fetch!(graph.nodes, edge.target)
        Task.async(fn -> walk(graph, target, pool, host, [], steps_left, :branch, false) end)
      end)
      |> Task.await_many(:infinity)

    executions = Enum.flat_map(results, &result_executions/1) ++ executions

    cond do
      error = Enum.find(results, &match?({:error, _id, _reason, _ex}, &1)) ->
        {:error, node_id, reason, _ex} = error
        {:error, node_id, reason, executions}

      paused = Enum.find(results, &match?({:paused, _id, _prompt, _pool, _ex}, &1)) ->
        {:paused, node_id, _prompt, _pool, _ex} = paused
        {:error, node_id, "human input inside parallel branches is not supported", executions}

      true ->
        merged_pool =
          Enum.reduce(results, pool, fn
            {:joined, _id, branch_pool, _ex}, acc -> merge_pool(acc, branch_pool)
            _done, acc -> acc
          end)

        joins = for {:joined, id, _pool, _ex} <- results, uniq: true, do: id
        done_outputs = for {:ok, outputs, _ex} <- results, do: outputs

        case joins do
          [] ->
            {:ok, Enum.reduce(done_outputs, %{}, &Map.merge(&2, &1)), executions}

          [join_id] ->
            join = Map.fetch!(graph.nodes, join_id)
            walk(graph, join, merged_pool, host, executions, steps_left - 1, mode, true)

          many ->
            {:error, nil,
             "parallel branches must converge on a single join node (found #{Enum.join(many, ", ")})",
             executions}
        end
    end
  end

  defp merge_pool(acc, branch_pool) do
    Map.merge(acc, branch_pool, fn
      "conversation", left, right when is_map(left) and is_map(right) -> Map.merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp result_executions({:ok, _outputs, executions}), do: executions
  defp result_executions({:error, _id, _reason, executions}), do: executions
  defp result_executions({:paused, _id, _prompt, _pool, executions}), do: executions
  defp result_executions({:joined, _id, _pool, executions}), do: executions

  # Nodes opting in via `cache_minutes` memoize their outputs through the
  # host's node cache, keyed on config + the full pool (conservative: any
  # upstream change busts the entry). Pause-capable results never cache.
  defp run_cached(node, pool, host) do
    ttl = node_cache_ttl(node)

    if ttl > 0 and match?(%{get: _get, put: _put}, host.node_cache) do
      key =
        {:node_cache, node.type, Map.delete(node.config, "__inputs__"), Map.delete(pool, "sys")}
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))

      case host.node_cache.get.(key) do
        {:ok, {outputs, branch}} ->
          Host.emit(host, {:node_cache_hit, %{node_id: node.id}})
          {:ok, outputs, branch}

        _miss ->
          with {:ok, outputs, branch} <- run_with_retries(node, pool, host, retries_for(node)) do
            host.node_cache.put.(key, {outputs, branch}, ttl)
            {:ok, outputs, branch}
          end
      end
    else
      run_with_retries(node, pool, host, retries_for(node))
    end
  end

  defp node_cache_ttl(node) do
    case node.config["cache_minutes"] do
      minutes when is_integer(minutes) and minutes > 0 -> min(minutes, 24 * 60)
      _off -> 0
    end
  end

  # Bounded, host-visible retries; the interval is capped so a
  # misconfigured node cannot stall the run for minutes.
  defp run_with_retries(node, pool, host, {max_retries, interval_ms}) do
    case safe_run(node, pool, host) do
      {:error, reason} when max_retries > 0 ->
        Host.emit(
          host,
          {:node_retry, %{node_id: node.id, error: format_error(reason), left: max_retries}}
        )

        Process.sleep(interval_ms)
        run_with_retries(node, pool, host, {max_retries - 1, interval_ms})

      result ->
        result
    end
  end

  defp retries_for(node) do
    retry = node.config["retry"] || %{}

    max_retries =
      case retry["max_retries"] do
        n when is_integer(n) and n > 0 -> min(n, 5)
        _off -> 0
      end

    interval_ms =
      case retry["interval_ms"] do
        n when is_integer(n) and n >= 0 -> min(n, 5_000)
        _default -> 500
      end

    {max_retries, interval_ms}
  end

  defp safe_run(node, pool, host) do
    # The executing node's id, readable by host capabilities (each
    # parallel branch is its own process, so this is branch-safe) — how
    # the embedding app attributes model usage per node.
    Process.put(:flux_engine_node_id, node.id)

    case Node.implementation(node.type).run(node, pool, host) do
      {:ok, outputs} -> {:ok, outputs, "default"}
      {:ok, outputs, branch} -> {:ok, outputs, branch}
      {:pause, prompt} -> {:pause, prompt}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  after
    Process.delete(:flux_engine_node_id)
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
