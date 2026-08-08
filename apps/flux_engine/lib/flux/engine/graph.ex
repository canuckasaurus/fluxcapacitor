defmodule Flux.Engine.Graph do
  @moduledoc """
  Validated in-memory form of a flux graph.

  Built from the JSON-shaped map the editor persists (`"nodes"`/`"edges"`
  lists with string keys). Drafts may be saved in any well-formed shape;
  `build/1` is the strict gate that running and publishing go through.
  """

  defmodule Node do
    @moduledoc "One node of a validated graph."
    @enforce_keys [:id, :type]
    defstruct [:id, :type, title: "", config: %{}, position: %{"x" => 0, "y" => 0}]

    @type t :: %__MODULE__{
            id: String.t(),
            type: String.t(),
            title: String.t(),
            config: map(),
            position: map()
          }
  end

  defmodule Edge do
    @moduledoc "A directed edge; `source_handle` names the branch it leaves from."
    @enforce_keys [:id, :source, :target]
    defstruct [:id, :source, :target, source_handle: "default"]

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            source_handle: String.t(),
            target: String.t()
          }
  end

  @enforce_keys [:nodes, :edges, :start_id]
  defstruct [:nodes, :edges, :start_id, env: %{}, conversation_variables: []]

  @type t :: %__MODULE__{
          nodes: %{String.t() => Node.t()},
          edges: [Edge.t()],
          start_id: String.t(),
          env: %{String.t() => String.t()},
          conversation_variables: [map()]
        }

  @node_types ~w(start llm if_else template answer end tool http_request code agent
                 variable_aggregator variable_assigner list_operator
                 question_classifier parameter_extractor document_extractor iteration
                 loop human_input labeling knowledge_retrieval document file_output
                 interview delay subflux)

  def node_types, do: @node_types

  @doc "Output handles a node type exposes (branching nodes have several)."
  def handles_for("if_else"), do: ~w(true false)
  def handles_for(_type), do: ~w(default)

  @doc "Output handles for a concrete node (classifier handles come from its classes)."
  def handles_for_node(%Node{type: "question_classifier", config: config}) do
    case Flux.Engine.Nodes.QuestionClassifier.classes(config) do
      [] -> ~w(default)
      classes -> Enum.map(classes, & &1["id"])
    end
  end

  def handles_for_node(%Node{type: "if_else", config: config}) do
    Enum.map(Flux.Engine.Nodes.IfElse.cases(config), & &1["id"]) ++ ["false"]
  end

  def handles_for_node(%Node{type: type}), do: handles_for(type)

  @doc """
  Validates the raw graph map and returns `{:ok, %Graph{}}` or
  `{:error, [message, ...]}` listing every problem found.
  """
  @spec build(map()) :: {:ok, t()} | {:error, [String.t()]}
  def build(raw) when is_map(raw) do
    nodes = raw |> Map.get("nodes", []) |> Enum.map(&to_node/1)
    edges = raw |> Map.get("edges", []) |> Enum.map(&to_edge/1)

    errors =
      []
      |> check_node_shapes(nodes)
      |> check_unique_ids(nodes)
      |> check_single_start(nodes)
      |> check_edges(nodes, edges)
      |> check_cycles(nodes, edges)

    case errors do
      [] ->
        [start] = Enum.filter(nodes, &(&1.type == "start"))

        {:ok,
         %__MODULE__{
           nodes: Map.new(nodes, &{&1.id, &1}),
           edges: edges,
           start_id: start.id,
           env: env(raw),
           conversation_variables: conversation_variables(raw)
         }}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  def build(_other), do: {:error, ["graph must be a map with \"nodes\" and \"edges\" lists"]}

  @doc "The edge leaving `node_id` on `handle`, or nil."
  def next_edge(%__MODULE__{edges: edges}, node_id, handle) do
    Enum.find(edges, &(&1.source == node_id and &1.source_handle == handle))
  end

  @doc "All edges leaving `node_id` on `handle` (several = parallel fan-out)."
  def next_edges(%__MODULE__{edges: edges}, node_id, handle) do
    Enum.filter(edges, &(&1.source == node_id and &1.source_handle == handle))
  end

  @doc "How many edges point at the node (>1 marks a join candidate)."
  def in_degree(%__MODULE__{edges: edges}, node_id) do
    Enum.count(edges, &(&1.target == node_id))
  end

  defp to_node(raw) when is_map(raw) do
    %Node{
      id: to_string(Map.get(raw, "id", "")),
      type: to_string(Map.get(raw, "type", "")),
      title: to_string(Map.get(raw, "title", "")),
      config: as_map(Map.get(raw, "config")),
      position: as_map(Map.get(raw, "position"))
    }
  end

  defp to_node(_raw), do: %Node{id: "", type: ""}

  defp to_edge(raw) when is_map(raw) do
    %Edge{
      id: to_string(Map.get(raw, "id", "")),
      source: to_string(Map.get(raw, "source", "")),
      source_handle: to_string(Map.get(raw, "source_handle", "default")),
      target: to_string(Map.get(raw, "target", ""))
    }
  end

  defp to_edge(_raw), do: %Edge{id: "", source: "", target: ""}

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  defp env(raw) do
    case Map.get(raw, "env") do
      %{} = env -> Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
      _absent -> %{}
    end
  end

  defp conversation_variables(raw) do
    raw
    |> Map.get("conversation_variables")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} = variable when is_binary(name) and name != "" ->
        [%{"name" => name, "default" => to_string(variable["default"] || "")}]

      _invalid ->
        []
    end)
  end

  defp check_node_shapes(errors, nodes) do
    Enum.reduce(nodes, errors, fn node, acc ->
      cond do
        node.id == "" -> ["a node is missing an id" | acc]
        node.id in ~w(env conversation sys) -> ["node id #{node.id} is reserved" | acc]
        node.type not in @node_types -> ["node #{node.id} has unknown type #{node.type}" | acc]
        true -> acc
      end
    end)
  end

  defp check_unique_ids(errors, nodes) do
    nodes
    |> Enum.frequencies_by(& &1.id)
    |> Enum.reduce(errors, fn
      {id, count}, acc when count > 1 -> ["duplicate node id #{id}" | acc]
      _entry, acc -> acc
    end)
  end

  defp check_single_start(errors, nodes) do
    case Enum.count(nodes, &(&1.type == "start")) do
      1 -> errors
      0 -> ["the graph needs a start node" | errors]
      n -> ["the graph has #{n} start nodes; only one is allowed" | errors]
    end
  end

  defp check_edges(errors, nodes, edges) do
    ids = MapSet.new(nodes, & &1.id)
    types = Map.new(nodes, &{&1.id, &1.type})
    by_id = Map.new(nodes, &{&1.id, &1})

    errors =
      Enum.reduce(edges, errors, fn edge, acc ->
        handles =
          case Map.get(by_id, edge.source) do
            nil ->
              ~w(default)

            # Any failable node may route an "error" branch (runner falls
            # back to failing the run when no such edge exists).
            %Node{type: type} = node when type not in ["start", "end"] ->
              handles_for_node(node) ++ ["error"]

            node ->
              handles_for_node(node)
          end

        cond do
          not MapSet.member?(ids, edge.source) ->
            ["edge #{edge.id} leaves unknown node #{edge.source}" | acc]

          not MapSet.member?(ids, edge.target) ->
            ["edge #{edge.id} points at unknown node #{edge.target}" | acc]

          edge.source_handle not in handles ->
            ["edge #{edge.id} uses handle #{edge.source_handle} not offered by its source" | acc]

          Map.get(types, edge.target) == "start" ->
            ["edge #{edge.id} points into the start node" | acc]

          true ->
            acc
        end
      end)

    # Multiple edges on one handle are legal: they fan out into parallel
    # branches (see Flux.Engine.Runner).
    errors
  end

  defp check_cycles(errors, nodes, edges) do
    adjacency = Enum.group_by(edges, & &1.source, & &1.target)

    cyclic? =
      Enum.any?(nodes, fn node ->
        cycle_from?(node.id, adjacency, MapSet.new(), MapSet.new()) == :cycle
      end)

    if cyclic?, do: ["the graph contains a cycle" | errors], else: errors
  end

  defp cycle_from?(id, adjacency, path, done) do
    cond do
      MapSet.member?(done, id) ->
        :ok

      MapSet.member?(path, id) ->
        :cycle

      true ->
        path = MapSet.put(path, id)

        adjacency
        |> Map.get(id, [])
        |> Enum.reduce_while(:ok, fn next, :ok ->
          case cycle_from?(next, adjacency, path, done) do
            :cycle -> {:halt, :cycle}
            :ok -> {:cont, :ok}
          end
        end)
    end
  end
end
