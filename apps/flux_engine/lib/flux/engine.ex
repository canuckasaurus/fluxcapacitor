defmodule Flux.Engine do
  @moduledoc """
  The flux workflow engine: a pure library that validates graph maps and
  executes them in the calling process.

  Everything effectful — model invocation, event delivery, persistence,
  process supervision — is injected through `Flux.Engine.Host` by the
  embedding application (`Flux.Workflows`).

      {:ok, graph} = Flux.Engine.build(graph_map)
      {:ok, result} = Flux.Engine.run(graph, %{"query" => "hi"}, host)

  Events emitted through the host during a run:

    * `{:workflow_started, %{inputs}}`
    * `{:node_started, %{node_id, node_type, title}}`
    * `{:node_chunk, %{node_id, delta}}` — LLM streaming and answer text
    * `{:node_finished, %{node_id, outputs, elapsed_ms}}`
    * `{:node_failed, %{node_id, error}}`
  """

  alias Flux.Engine.{Graph, Host, Runner}

  defdelegate build(graph_map), to: Graph
  defdelegate node_types(), to: Graph
  defdelegate handles_for(type), to: Graph

  @spec run(Graph.t(), map(), Host.t()) :: {:ok, Runner.success()} | {:error, Runner.failure()}
  defdelegate run(graph, inputs, host), to: Runner
end
