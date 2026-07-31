defmodule Flux.Engine.Nodes.Start do
  @moduledoc """
  Validates the run's inputs against the declared variables and seeds the
  pool. Config: `%{"variables" => [%{"name", "label", "type", "required"}]}`
  with type `"text" | "paragraph" | "number"`.
  """
  @behaviour Flux.Engine.Node

  @impl true
  def run(node, _pool, _host) do
    variables = List.wrap(node.config["variables"])
    inputs = Map.get(node.config, "__inputs__", %{})

    Enum.reduce_while(variables, {:ok, %{}}, fn variable, {:ok, outputs} ->
      name = to_string(variable["name"] || "")
      value = Map.get(inputs, name)

      case coerce(variable["type"] || "text", value) do
        {:ok, nil} ->
          if variable["required"] do
            {:halt, {:error, "input #{name} is required"}}
          else
            {:cont, {:ok, outputs}}
          end

        {:ok, coerced} ->
          {:cont, {:ok, Map.put(outputs, name, coerced)}}

        {:error, message} ->
          {:halt, {:error, "input #{name}: #{message}"}}
      end
    end)
  end

  defp coerce(_type, nil), do: {:ok, nil}
  defp coerce(_type, ""), do: {:ok, nil}

  defp coerce("number", value) when is_number(value), do: {:ok, value}

  defp coerce("number", value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, trunc_if_whole(number)}
      _other -> {:error, "must be a number"}
    end
  end

  defp coerce(_text_type, value) when is_binary(value), do: {:ok, value}
  defp coerce(_type, value), do: {:ok, to_string(value)}

  defp trunc_if_whole(number) do
    truncated = trunc(number)
    if truncated == number, do: truncated, else: number
  end
end

defmodule Flux.Engine.Nodes.LLM do
  @moduledoc """
  Renders the prompt templates and invokes the model through the host.
  Config: `provider_plugin_id`, `model`, `system_prompt`, `prompt`, `params`.
  Outputs `%{"text" => content, "usage" => usage}`; streams deltas as
  `{:node_chunk, %{node_id, delta}}` events.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    plugin_id = to_string(node.config["provider_plugin_id"] || "")
    model = to_string(node.config["model"] || "")

    with :ok <- require_config(plugin_id != "" and model != ""),
         {:ok, invoke} <- fetch_invoker(host) do
      system = Template.render(node.config["system_prompt"], pool)
      prompt = Template.render(node.config["prompt"], pool)

      messages =
        if system == "" do
          [%{role: :user, content: prompt}]
        else
          [%{role: :system, content: system}, %{role: :user, content: prompt}]
        end

      request = %{
        provider_plugin_id: plugin_id,
        model: model,
        messages: messages,
        params: node.config["params"] || %{}
      }

      chunk_emit = fn delta ->
        Host.emit(host, {:node_chunk, %{node_id: node.id, delta: delta}})
      end

      case invoke.(request, chunk_emit) do
        {:ok, %{content: content} = result} ->
          {:ok, %{"text" => content, "usage" => Map.get(result, :usage, %{})}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp require_config(true), do: :ok
  defp require_config(false), do: {:error, "the LLM node needs a provider and model"}

  defp fetch_invoker(%Host{invoke_llm: invoke}) when is_function(invoke, 2), do: {:ok, invoke}
  defp fetch_invoker(_host), do: {:error, "this run's host cannot invoke models"}
end

defmodule Flux.Engine.Nodes.IfElse do
  @moduledoc """
  Evaluates rendered conditions and branches on handle `"true"`/`"false"`.
  Config: `%{"logical_operator" => "and" | "or", "conditions" =>
  [%{"left", "operator", "right"}]}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @operators ~w(contains not_contains equals not_equals starts_with ends_with
                is_empty is_not_empty gt gte lt lte)

  def operators, do: @operators

  @impl true
  def run(node, pool, _host) do
    conditions = List.wrap(node.config["conditions"])

    with {:ok, verdicts} <- evaluate_all(conditions, pool) do
      result =
        case {node.config["logical_operator"] || "and", verdicts} do
          {_operator, []} -> false
          {"or", verdicts} -> Enum.any?(verdicts)
          {_and, verdicts} -> Enum.all?(verdicts)
        end

      {:ok, %{"result" => result}, to_string(result)}
    end
  end

  defp evaluate_all(conditions, pool) do
    Enum.reduce_while(conditions, {:ok, []}, fn condition, {:ok, acc} ->
      left = Template.render(condition["left"], pool)
      right = Template.render(condition["right"], pool)

      case evaluate(condition["operator"] || "equals", left, right) do
        {:ok, verdict} -> {:cont, {:ok, [verdict | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp evaluate("contains", left, right), do: {:ok, String.contains?(left, right)}
  defp evaluate("not_contains", left, right), do: {:ok, not String.contains?(left, right)}
  defp evaluate("equals", left, right), do: {:ok, left == right}
  defp evaluate("not_equals", left, right), do: {:ok, left != right}
  defp evaluate("starts_with", left, right), do: {:ok, String.starts_with?(left, right)}
  defp evaluate("ends_with", left, right), do: {:ok, String.ends_with?(left, right)}
  defp evaluate("is_empty", left, _right), do: {:ok, String.trim(left) == ""}
  defp evaluate("is_not_empty", left, _right), do: {:ok, String.trim(left) != ""}

  defp evaluate(numeric, left, right) when numeric in ~w(gt gte lt lte) do
    with {left_number, ""} <- Float.parse(left),
         {right_number, ""} <- Float.parse(right) do
      verdict =
        case numeric do
          "gt" -> left_number > right_number
          "gte" -> left_number >= right_number
          "lt" -> left_number < right_number
          "lte" -> left_number <= right_number
        end

      {:ok, verdict}
    else
      _not_numeric -> {:ok, false}
    end
  end

  defp evaluate(operator, _left, _right), do: {:error, "unknown operator #{operator}"}
end

defmodule Flux.Engine.Nodes.TemplateTransform do
  @moduledoc ~S(Renders `config["template"]`; outputs `%{"output" => text}`.)
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @impl true
  def run(node, pool, _host) do
    {:ok, %{"output" => Template.render(node.config["template"], pool)}}
  end
end

defmodule Flux.Engine.Nodes.Answer do
  @moduledoc """
  Renders `config["answer"]` as the user-facing reply, streaming it as one
  `{:node_chunk, ...}` event. Outputs `%{"answer" => text}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    answer = Template.render(node.config["answer"], pool)
    Host.emit(host, {:node_chunk, %{node_id: node.id, delta: answer}})
    {:ok, %{"answer" => answer}}
  end
end

defmodule Flux.Engine.Nodes.Tool do
  @moduledoc """
  Calls one operation of an imported API toolset through the host.
  Config: `%{"toolset_id", "operation_id", "args" => %{name => template}}`.
  Outputs `%{"status" => integer, "body" => term, "text" => binary}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    toolset_id = to_string(node.config["toolset_id"] || "")
    operation_id = to_string(node.config["operation_id"] || "")

    with :ok <- require_config(toolset_id != "" and operation_id != ""),
         {:ok, invoke} <- fetch_invoker(host) do
      args =
        node.config["args"]
        |> as_map()
        |> Map.new(fn {name, template} -> {name, Template.render(template, pool)} end)

      case invoke.(%{toolset_id: toolset_id, operation_id: operation_id, args: args}) do
        {:ok, %{status: status} = result} ->
          {:ok,
           %{
             "status" => status,
             "body" => Map.get(result, :body),
             "text" => Map.get(result, :text, "")
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp as_map(args) when is_map(args), do: args
  defp as_map(_args), do: %{}

  defp require_config(true), do: :ok
  defp require_config(false), do: {:error, "the tool node needs a toolset and operation"}

  defp fetch_invoker(%Host{invoke_tool: invoke}) when is_function(invoke, 1), do: {:ok, invoke}
  defp fetch_invoker(_host), do: {:error, "this run's host cannot call tools"}
end

defmodule Flux.Engine.Nodes.HttpRequest do
  @moduledoc """
  Makes an HTTP call through the host (which owns SSRF guarding and the
  client). Config: `method`, `url` (template), `headers` ([{key, value}]
  with template values), `body` (template, sent raw; JSON content-type when
  it parses as JSON). Outputs `%{"status_code", "body", "text"}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    url = Template.render(node.config["url"], pool)

    with :ok <- require_config(url != ""),
         {:ok, request} <- fetch_requester(host) do
      headers =
        node.config["headers"]
        |> List.wrap()
        |> Enum.map(fn header ->
          {to_string(header["key"] || ""), Template.render(header["value"], pool)}
        end)
        |> Enum.reject(fn {key, _value} -> key == "" end)

      spec = %{
        method: String.downcase(to_string(node.config["method"] || "get")),
        url: url,
        headers: headers,
        body: Template.render(node.config["body"], pool)
      }

      case request.(spec) do
        {:ok, %{status: status} = result} ->
          {:ok,
           %{
             "status_code" => status,
             "body" => Map.get(result, :body),
             "text" => Map.get(result, :text, "")
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp require_config(true), do: :ok
  defp require_config(false), do: {:error, "the HTTP request node needs a URL"}

  defp fetch_requester(%Host{http_request: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp fetch_requester(_host), do: {:error, "this run's host cannot make HTTP requests"}
end

defmodule Flux.Engine.Nodes.Code do
  @moduledoc """
  Executes a code block through the host's `run_code` capability
  (Dify-compatible `main(**inputs) -> dict` contract, plus per-block
  `dependencies`). Config: `language`, `code`,
  `dependencies` ([{name, version}]), `inputs` ([{name, value-template}]),
  `timeout_ms`. Outputs: the returned dict's keys plus `"stdout"`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    code = to_string(node.config["code"] || "")

    with :ok <- require_config(code != ""),
         {:ok, runner} <- fetch_runner(host) do
      inputs =
        node.config["inputs"]
        |> List.wrap()
        |> Map.new(fn input ->
          {to_string(input["name"] || ""), Template.render(input["value"], pool)}
        end)
        |> Map.delete("")

      spec = %{
        language: to_string(node.config["language"] || "python3"),
        code: code,
        dependencies:
          node.config["dependencies"]
          |> List.wrap()
          |> Enum.filter(&(to_string(&1["name"] || "") != "")),
        inputs: inputs,
        timeout_ms: node.config["timeout_ms"] || 30_000
      }

      case runner.(spec) do
        {:ok, %{result: %{} = result} = response} ->
          outputs = Map.new(result, fn {key, value} -> {to_string(key), value} end)
          {:ok, Map.put(outputs, "stdout", Map.get(response, :stdout, ""))}

        {:ok, _bad_shape} ->
          {:error, "the code block's main() must return a dict/object"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp require_config(true), do: :ok
  defp require_config(false), do: {:error, "the code node has no code"}

  defp fetch_runner(%Host{run_code: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp fetch_runner(_host), do: {:error, "this run's host cannot execute code"}
end

defmodule Flux.Engine.Nodes.Agent do
  @moduledoc """
  Autonomous tool-calling loop: the model may call any of the node's
  configured tools (snapshotted toolset operations) until it answers in
  plain text or `max_iterations` is hit — the guard upstream Dify v2 lacks.

  Config: `provider_plugin_id`, `model`, `instructions`, `query`
  (template), `max_iterations` (default 5),
  `tools` ([{name, description, parameters, toolset_id, operation_id}]).
  Outputs `%{"text", "iterations", "tool_calls"}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    plugin_id = to_string(node.config["provider_plugin_id"] || "")
    model = to_string(node.config["model"] || "")

    with :ok <- require_config(plugin_id != "" and model != ""),
         {:ok, invoke_llm} <- capability(host, :invoke_llm, 2),
         {:ok, invoke_tool} <- capability(host, :invoke_tool, 1) do
      instructions = Template.render(node.config["instructions"], pool)
      query = Template.render(node.config["query"], pool)
      tools = List.wrap(node.config["tools"])

      messages =
        if instructions == "" do
          [%{role: :user, content: query}]
        else
          [%{role: :system, content: instructions}, %{role: :user, content: query}]
        end

      max_iterations = node.config["max_iterations"] || 5

      chunk_emit = fn delta ->
        Host.emit(host, {:node_chunk, %{node_id: node.id, delta: delta}})
      end

      context = %{
        node: node,
        host: host,
        plugin_id: plugin_id,
        model: model,
        tools: tools,
        invoke_llm: invoke_llm,
        invoke_tool: invoke_tool,
        chunk_emit: chunk_emit
      }

      loop(context, messages, 1, max_iterations, 0)
    end
  end

  defp loop(_context, _messages, iteration, max_iterations, _calls)
       when iteration > max_iterations do
    {:error, "agent exceeded max_iterations (#{max_iterations}) without a final answer"}
  end

  defp loop(context, messages, iteration, max_iterations, calls_so_far) do
    request = %{
      provider_plugin_id: context.plugin_id,
      model: context.model,
      messages: messages,
      params: context.node.config["params"] || %{},
      tools: Enum.map(context.tools, &Map.take(&1, ["name", "description", "parameters"]))
    }

    case context.invoke_llm.(request, context.chunk_emit) do
      {:ok, %{tool_calls: [_call | _] = tool_calls} = result} ->
        assistant = %{role: :assistant, content: result.content, tool_calls: tool_calls}
        tool_messages = Enum.map(tool_calls, &execute_tool(context, &1))

        loop(
          context,
          messages ++ [assistant | tool_messages],
          iteration + 1,
          max_iterations,
          calls_so_far + length(tool_calls)
        )

      {:ok, result} ->
        {:ok,
         %{
           "text" => result.content,
           "iterations" => iteration,
           "tool_calls" => calls_so_far
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tool(context, call) do
    Host.emit(
      context.host,
      {:agent_tool_call, %{node_id: context.node.id, tool: call.name, arguments: call.arguments}}
    )

    content =
      case Enum.find(context.tools, &(&1["name"] == call.name)) do
        nil ->
          "error: unknown tool #{call.name}"

        tool ->
          case context.invoke_tool.(%{
                 toolset_id: tool["toolset_id"],
                 operation_id: tool["operation_id"],
                 args: stringify(call.arguments)
               }) do
            {:ok, %{text: text}} -> String.slice(text, 0, 8_000)
            {:error, reason} -> "error: #{inspect(reason)}"
          end
      end

    %{role: :tool, tool_call_id: call.id, name: call.name, content: content}
  end

  defp stringify(arguments) when is_map(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify(_arguments), do: %{}

  defp require_config(true), do: :ok
  defp require_config(false), do: {:error, "the agent node needs a provider and model"}

  defp capability(host, key, arity) do
    case Map.get(host, key) do
      fun when is_function(fun, arity) -> {:ok, fun}
      _missing -> {:error, "this run's host cannot #{key}"}
    end
  end
end

defmodule Flux.Engine.Nodes.EndNode do
  @moduledoc """
  Collects the run's final outputs. Config:
  `%{"outputs" => [%{"key", "value"}]}` where each value is a template.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @impl true
  def run(node, pool, _host) do
    outputs =
      node.config["outputs"]
      |> List.wrap()
      |> Enum.reduce(%{}, fn mapping, acc ->
        case to_string(mapping["key"] || "") do
          "" -> acc
          key -> Map.put(acc, key, Template.render(mapping["value"], pool))
        end
      end)

    {:ok, outputs}
  end
end
