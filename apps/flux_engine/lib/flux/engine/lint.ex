defmodule Flux.Engine.Lint do
  @moduledoc """
  Advisory checks the strict validator doesn't enforce: every
  `{{node.field}}` template reference in a node's config should name a
  known namespace or a node that is actually upstream — anything else
  renders as an empty string at run time, which is legal but almost
  always a typo. Returns human-readable warnings; never blocks a run.
  """

  @namespaces ~w(env sys conversation inputs vars item index)

  @reference ~r/\{\{\s*([A-Za-z0-9_\-]+)(?:\.[A-Za-z0-9_\-\.]+)?\s*\}\}/

  @doc "Warnings for unresolvable template references in the raw graph map."
  def reference_warnings(graph_map) when is_map(graph_map) do
    nodes = List.wrap(graph_map["nodes"])
    edges = List.wrap(graph_map["edges"])
    ids = MapSet.new(nodes, &to_string(&1["id"] || ""))
    ancestors = ancestors_map(edges)

    for node <- nodes,
        node_id = to_string(node["id"] || ""),
        source <- Enum.uniq(referenced_sources(node["config"])),
        warning = check(source, node_id, ids, ancestors),
        warning != nil,
        uniq: true do
      warning
    end
  end

  def reference_warnings(_graph), do: []

  defp check(source, node_id, ids, ancestors) do
    cond do
      source in @namespaces ->
        nil

      # Self-references are legal (loop break conditions read their own id).
      source == node_id ->
        nil

      not MapSet.member?(ids, source) ->
        "#{node_id} references {{#{source}.…}} but no node \"#{source}\" exists"

      not MapSet.member?(Map.get(ancestors, node_id, MapSet.new()), source) ->
        "#{node_id} references {{#{source}.…}} but \"#{source}\" is not upstream of it"

      true ->
        nil
    end
  end

  # Every {{ref}} source name found anywhere in the config's string values.
  defp referenced_sources(config) when is_map(config) do
    config
    |> deep_strings()
    |> Enum.flat_map(fn text ->
      @reference
      |> Regex.scan(text)
      |> Enum.map(fn [_whole, source] -> source end)
    end)
  end

  defp referenced_sources(_config), do: []

  defp deep_strings(value) when is_binary(value), do: [value]
  defp deep_strings(value) when is_map(value), do: Enum.flat_map(value, &deep_strings/1)
  defp deep_strings({_key, value}), do: deep_strings(value)
  defp deep_strings(value) when is_list(value), do: Enum.flat_map(value, &deep_strings/1)
  defp deep_strings(_other), do: []

  # node id → MapSet of every id reachable walking edges backwards.
  defp ancestors_map(edges) do
    incoming =
      Enum.group_by(edges, &to_string(&1["target"] || ""), &to_string(&1["source"] || ""))

    incoming
    |> Map.keys()
    |> Enum.reduce(%{}, fn id, acc -> Map.put(acc, id, collect_ancestors(id, incoming, %{})) end)
  end

  defp collect_ancestors(id, incoming, _memo) do
    do_collect(id, incoming, MapSet.new())
  end

  defp do_collect(id, incoming, seen) do
    incoming
    |> Map.get(id, [])
    |> Enum.reduce(seen, fn parent, acc ->
      if MapSet.member?(acc, parent) do
        acc
      else
        do_collect(parent, incoming, MapSet.put(acc, parent))
      end
    end)
  end
end
