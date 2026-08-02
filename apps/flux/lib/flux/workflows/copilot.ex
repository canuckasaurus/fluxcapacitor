defmodule Flux.Workflows.Copilot do
  @moduledoc """
  AI drafting for the flux creation flow: a plain-language description
  becomes a draft graph through the workspace's default model. Nothing
  is trusted — the generated JSON must pass `Flux.Engine.build/1`
  before it reaches a draft, with one corrective retry when it doesn't.

  Tests inject `config :flux, Flux.Workflows.Copilot, module:` to fake
  the model call.
  """

  alias Flux.Accounts.Scope
  alias Flux.Providers

  @reference_path Path.expand("../../../../../docs/guides/node-reference.md", __DIR__)
  @external_resource @reference_path

  # The distilled catalog: the guide's intro + node table, not the prose.
  @node_catalog @reference_path
                |> File.read!()
                |> String.split("## Nodes in detail")
                |> hd()
                |> String.trim()

  @system_prompt """
  You design workflow graphs ("fluxes") for the FluxCapacitor platform.
  The user describes what they want; you answer with ONE JSON object and
  nothing else — no prose, no markdown fences.

  Response shape:
  {"name": "Short flux name", "nodes": [...], "edges": [...]}

  Every node: {"id", "type", "title", "config"} (positions are laid out
  automatically). Every edge: {"source", "source_handle", "target"} —
  source_handle is "default" except branch handles (if_else: "true"/
  "false"; question_classifier: the class id; error routes: "error").

  Rules:
  - Exactly one `start` node (id "start") declaring the run's inputs:
    config {"variables": [{"name", "label", "type": "text", "required": true}]}.
  - End with an `end` node mapping outputs:
    config {"outputs": [{"key": "result", "value": "{{node_id.text}}"}]},
    or an `answer` node (config {"answer": "..."}) for chat-style fluxes.
  - Reference upstream values with {{node_id.output_key}} templates.
  - llm nodes: config {"system_prompt", "prompt"} — leave provider/model
    out; the workspace default model is used.
  - template nodes: config {"template": "..."} → output {{id.output}}.
  - if_else nodes: config {"conditions": [{"left": "{{start.x}}",
    "operator": "contains", "right": "y"}], "logical_operator": "and"};
    operators: contains, not_contains, equals, not_equals, starts_with,
    ends_with, is_empty, is_not_empty, gt, lt, gte, lte.
  - code nodes: config {"language": "python3", "code": "def main(**inputs): ...",
    "inputs": [{"name": "x", "value": "{{start.x}}"}]} — main returns a dict.
  - http_request nodes: config {"method", "url", "headers", "body"}.
  - Keep graphs minimal: only nodes the task needs, every node reachable
    from start, no cycles.

  Node catalog:

  #{@node_catalog}
  """

  @doc """
  Drafts a graph from a description. Returns
  `{:ok, %{name, graph, warnings}}` (graph already validated by the
  engine, warnings from the reference linter) or `{:error, message}`.
  """
  def draft(%Scope{} = scope, description) do
    description = String.trim(to_string(description || ""))

    cond do
      description == "" ->
        {:error, "Describe the flux you want first."}

      config()[:module] == nil and Providers.default_model(scope) == nil ->
        {:error, "The AI helper needs a workspace default model — pick one on the Plugins page."}

      true ->
        messages = [
          %{role: :system, content: @system_prompt},
          %{role: :user, content: description}
        ]

        attempt(scope, messages, _retries_left = 1)
    end
  end

  defp attempt(scope, messages, retries_left) do
    with {:ok, content} <- generate(scope, messages),
         {:ok, name, graph} <- parse(content),
         {:ok, _built} <- Flux.Engine.build(graph) do
      {:ok, %{name: name, graph: graph, warnings: Flux.Engine.Lint.reference_warnings(graph)}}
    else
      {:error, message} when retries_left > 0 ->
        correction = [
          %{
            role: :user,
            content:
              "That graph failed validation: #{message}. " <>
                "Reply with the corrected JSON object only."
          }
        ]

        attempt(scope, messages ++ correction, retries_left - 1)

      {:error, message} ->
        {:error, "The helper could not produce a valid flux: #{message}"}
    end
  end

  defp generate(scope, messages) do
    case config()[:module] do
      nil -> Flux.Workflows.invoke_default_llm(scope, messages)
      module -> module.generate(messages)
    end
  end

  defp parse(content) do
    with {:ok, decoded} <- decode_json(content),
         {:ok, nodes} <- fetch_list(decoded, "nodes"),
         {:ok, edges} <- fetch_list(decoded, "edges") do
      name =
        case String.trim(to_string(decoded["name"] || "")) do
          "" -> "AI draft"
          name -> String.slice(name, 0, 80)
        end

      graph = %{
        "nodes" => nodes |> Enum.with_index() |> Enum.map(&normalize_node/1),
        "edges" => edges |> Enum.with_index() |> Enum.map(&normalize_edge/1)
      }

      {:ok, name, graph}
    end
  end

  # Models love to wrap JSON in fences or preamble; take the outermost object.
  defp decode_json(content) do
    content = to_string(content)

    with {first, _} <- :binary.match(content, "{"),
         [{last, _} | _] <- content |> :binary.matches("}") |> Enum.reverse(),
         true <- last >= first,
         {:ok, %{} = decoded} <-
           content |> binary_part(first, last - first + 1) |> Jason.decode() do
      {:ok, decoded}
    else
      _no_object -> {:error, "the model did not return a JSON object"}
    end
  end

  defp fetch_list(decoded, key) do
    case decoded[key] do
      [_ | _] = list -> {:ok, Enum.filter(list, &is_map/1)}
      _missing -> {:error, "the graph needs a non-empty #{String.trim_trailing(key, "s")} list"}
    end
  end

  defp normalize_node({node, index}) do
    %{
      "id" => to_string(node["id"] || "node_#{index + 1}"),
      "type" => to_string(node["type"] || ""),
      "title" => to_string(node["title"] || node["id"] || "Node"),
      "position" => node["position"] || auto_position(index),
      "config" => (is_map(node["config"]) && node["config"]) || %{}
    }
  end

  # A readable default layout: left-to-right lanes, staggered rows.
  defp auto_position(index) do
    %{"x" => 80 + index * 300, "y" => 120 + rem(index, 2) * 160}
  end

  defp normalize_edge({edge, index}) do
    %{
      "id" => to_string(edge["id"] || "edge_#{index + 1}"),
      "source" => to_string(edge["source"] || ""),
      "source_handle" => to_string(edge["source_handle"] || "default"),
      "target" => to_string(edge["target"] || "")
    }
  end

  defp config, do: Application.get_env(:flux, __MODULE__, [])
end
