defmodule Flux.Workflows.DSL do
  @moduledoc """
  Imports Dify app DSL (the `kind: app` YAML export, current version 0.7.x)
  into a flux graph.

  Node types supported today: start, llm, if-else, answer, end,
  template-transform. Unsupported nodes (and edges touching them) are
  dropped and reported as warnings so partial imports remain editable.
  Dify variable selectors (`{{#node.field#}}`, `value_selector` lists,
  Jinja arguments in template-transform) convert to `{{node.field}}`.
  """

  @supported %{
    "start" => "start",
    "llm" => "llm",
    "if-else" => "if_else",
    "answer" => "answer",
    "end" => "end",
    "template-transform" => "template"
  }

  @operator_map %{
    "contains" => "contains",
    "not contains" => "not_contains",
    "start with" => "starts_with",
    "end with" => "ends_with",
    "is" => "equals",
    "is not" => "not_equals",
    "empty" => "is_empty",
    "not empty" => "is_not_empty",
    "=" => "equals",
    "≠" => "not_equals",
    ">" => "gt",
    "<" => "lt",
    "≥" => "gte",
    "≤" => "lte"
  }

  @doc """
  Returns `{:ok, %{name, description, mode, graph, warnings}}` or
  `{:error, message}`.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(yaml) when is_binary(yaml) do
    with {:ok, doc} <- decode(yaml),
         :ok <- validate(doc) do
      raw_nodes = get_in(doc, ["workflow", "graph", "nodes"]) || []
      raw_edges = get_in(doc, ["workflow", "graph", "edges"]) || []

      {nodes, warnings} = convert_nodes(raw_nodes)
      kept_ids = MapSet.new(nodes, & &1["id"])
      {edges, warnings} = convert_edges(raw_edges, raw_nodes, kept_ids, warnings)

      {:ok,
       %{
         name: get_in(doc, ["app", "name"]) || "Imported flux",
         description: get_in(doc, ["app", "description"]),
         mode: get_in(doc, ["app", "mode"]),
         graph: %{"nodes" => nodes, "edges" => edges},
         warnings: Enum.reverse(warnings)
       }}
    end
  end

  defp decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      _invalid -> {:error, "Not valid YAML (expected a Dify app DSL document)."}
    end
  end

  defp validate(doc) do
    mode = get_in(doc, ["app", "mode"])

    cond do
      not is_map(doc["app"]) ->
        {:error, "Missing app section — is this a Dify DSL export?"}

      mode not in ["workflow", "advanced-chat"] ->
        {:error, "Only workflow and advanced-chat DSLs are importable (got #{mode || "none"})."}

      not is_map(get_in(doc, ["workflow", "graph"])) ->
        {:error, "The DSL has no workflow graph."}

      true ->
        :ok
    end
  end

  ## Nodes

  defp convert_nodes(raw_nodes) do
    Enum.reduce(raw_nodes, {[], []}, fn raw, {nodes, warnings} ->
      dify_type = get_in(raw, ["data", "type"])

      case Map.get(@supported, dify_type) do
        nil ->
          {nodes, [unsupported_warning(raw, dify_type) | warnings]}

        type ->
          {node, node_warnings} = convert_node(raw, type)
          {nodes ++ [node], node_warnings ++ warnings}
      end
    end)
  end

  defp unsupported_warning(raw, dify_type) do
    title = get_in(raw, ["data", "title"]) || raw["id"]
    "Dropped unsupported node #{inspect(title)} (type #{inspect(dify_type)})."
  end

  defp convert_node(raw, type) do
    data = raw["data"] || %{}
    {config, warnings} = convert_config(type, data)

    {%{
       "id" => to_string(raw["id"]),
       "type" => type,
       "title" => data["title"] || type,
       "position" => %{
         "x" => round(num(get_in(raw, ["position", "x"]))),
         "y" => round(num(get_in(raw, ["position", "y"])))
       },
       "config" => config
     }, warnings}
  end

  defp convert_config("start", data) do
    variables =
      data["variables"]
      |> List.wrap()
      |> Enum.map(fn variable ->
        %{
          "name" => variable["variable"],
          "label" => variable["label"] || variable["variable"],
          "type" => start_var_type(variable["type"]),
          "required" => variable["required"] == true
        }
      end)

    {%{"variables" => variables}, []}
  end

  defp convert_config("llm", data) do
    model = data["model"] || %{}
    {provider, provider_warnings} = map_provider(model["provider"])

    {system, prompt} = split_prompt_template(data["prompt_template"])

    params =
      (model["completion_params"] || %{})
      |> Map.take(["temperature", "max_tokens", "top_p"])

    {%{
       "provider_plugin_id" => provider,
       "model" => model["name"] || "",
       "system_prompt" => convert_selectors(system),
       "prompt" => convert_selectors(prompt),
       "params" => params
     }, provider_warnings}
  end

  defp convert_config("if_else", data) do
    case List.wrap(data["cases"]) do
      [] ->
        # Pre-cases DSL: conditions live directly on data.
        {build_conditions(data), []}

      [first | rest] ->
        warnings =
          if rest == [] do
            []
          else
            ["if-else node has #{length(rest)} extra case(s); only the first imported."]
          end

        {build_conditions(first), warnings}
    end
  end

  defp convert_config("answer", data) do
    {%{"answer" => convert_selectors(data["answer"] || "")}, []}
  end

  defp convert_config("end", data) do
    outputs =
      data["outputs"]
      |> List.wrap()
      |> Enum.map(fn output ->
        %{"key" => output["variable"], "value" => selector_ref(output["value_selector"])}
      end)

    {%{"outputs" => outputs}, []}
  end

  defp convert_config("template", data) do
    template =
      data["variables"]
      |> List.wrap()
      |> Enum.reduce(data["template"] || "", fn variable, template ->
        reference = selector_ref(variable["value_selector"])

        Regex.replace(
          ~r/\{\{\s*#{Regex.escape(variable["variable"] || "")}\s*\}\}/,
          template,
          reference
        )
      end)

    warnings =
      if template =~ ~r/\{%/ do
        ["template-transform uses Jinja control blocks ({% %}); those are not evaluated."]
      else
        []
      end

    {%{"template" => template}, warnings}
  end

  defp build_conditions(case_or_data) do
    conditions =
      case_or_data["conditions"]
      |> List.wrap()
      |> Enum.map(fn condition ->
        %{
          "left" => selector_ref(condition["variable_selector"]),
          "operator" => Map.get(@operator_map, condition["comparison_operator"], "equals"),
          "right" => to_string(condition["value"] || "")
        }
      end)

    %{
      "logical_operator" => case_or_data["logical_operator"] || "and",
      "conditions" => conditions
    }
  end

  ## Edges

  defp convert_edges(raw_edges, raw_nodes, kept_ids, warnings) do
    if_else_case_ids = first_case_ids(raw_nodes)

    Enum.reduce(raw_edges, {[], warnings}, fn raw, {edges, warnings} ->
      source = to_string(raw["source"])
      target = to_string(raw["target"])

      if not MapSet.member?(kept_ids, source) or not MapSet.member?(kept_ids, target) do
        {edges, warnings}
      else
        case map_handle(raw["sourceHandle"], Map.get(if_else_case_ids, source)) do
          {:ok, handle} ->
            edge = %{
              "id" => to_string(raw["id"]),
              "source" => source,
              "source_handle" => handle,
              "target" => target
            }

            {edges ++ [edge], warnings}

          :drop ->
            {edges,
             [
               "Dropped edge #{raw["id"]} (unsupported branch handle #{raw["sourceHandle"]})."
               | warnings
             ]}
        end
      end
    end)
  end

  defp first_case_ids(raw_nodes) do
    for raw <- raw_nodes,
        get_in(raw, ["data", "type"]) == "if-else",
        first_case = raw |> get_in(["data", "cases"]) |> List.wrap() |> List.first(),
        into: %{} do
      {to_string(raw["id"]), to_string(first_case["case_id"] || "true")}
    end
  end

  defp map_handle("source", _first_case), do: {:ok, "default"}
  defp map_handle("false", _first_case), do: {:ok, "false"}
  defp map_handle("true", _first_case), do: {:ok, "true"}

  defp map_handle(handle, first_case) when is_binary(handle) do
    if handle == first_case, do: {:ok, "true"}, else: :drop
  end

  defp map_handle(_handle, _first_case), do: {:ok, "default"}

  ## Selector / provider helpers

  # {{#17541.query#}} → {{17541.query}}; also {{#sys.query#}} passes through
  # (renders blank at runtime, harmless).
  defp convert_selectors(nil), do: ""

  defp convert_selectors(text) when is_binary(text) do
    Regex.replace(~r/\{\{#\s*([\w\.\-]+)\s*#\}\}/, text, "{{\\1}}")
  end

  defp selector_ref(selector) when is_list(selector) and selector != [],
    do: "{{" <> Enum.map_join(selector, ".", &to_string/1) <> "}}"

  defp selector_ref(_selector), do: ""

  defp split_prompt_template(prompts) when is_list(prompts) do
    {system, rest} =
      Enum.split_with(prompts, fn prompt -> prompt["role"] == "system" end)

    {Enum.map_join(system, "\n\n", & &1["text"]), Enum.map_join(rest, "\n\n", & &1["text"])}
  end

  defp split_prompt_template(%{"text" => text}), do: {"", text}
  defp split_prompt_template(_other), do: {"", ""}

  defp map_provider(provider) when provider in [nil, ""], do: {"", []}

  defp map_provider(provider) do
    normalized = String.downcase(provider)

    cond do
      normalized =~ "openai" and normalized =~ "azure" ->
        {"openai", ["Azure OpenAI mapped to the plain openai provider."]}

      normalized =~ "openai" ->
        {"openai", []}

      normalized =~ "anthropic" ->
        {"anthropic", []}

      normalized =~ "google" or normalized =~ "gemini" ->
        {"gemini", []}

      true ->
        fallback = provider |> String.split("/") |> List.last()
        {fallback, ["Unknown provider #{inspect(provider)}; kept as #{inspect(fallback)}."]}
    end
  end

  defp start_var_type("paragraph"), do: "paragraph"
  defp start_var_type("number"), do: "number"
  defp start_var_type(_other), do: "text"

  defp num(value) when is_number(value), do: value
  defp num(_value), do: 0
end
