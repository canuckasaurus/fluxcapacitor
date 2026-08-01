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
  Config: `provider_plugin_id`, `model`, `system_prompt`, `prompt`,
  `params`, and optional `output_schema` (a JSON schema) — when set, a
  forced `respond` tool call yields a structured `"output"` map.
  Outputs `%{"text", "usage"}` (+ `"output"` with a schema); streams
  deltas as `{:node_chunk, %{node_id, delta}}` events.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    {plugin_id, model} = Host.resolve_llm(host, node.config)

    with :ok <- require_config(plugin_id != "" and model != ""),
         {:ok, invoke} <- fetch_invoker(host) do
      system = Template.render(node.config["system_prompt"], pool)
      prompt = Template.render(node.config["prompt"], pool)
      schema = node.config["output_schema"]

      system =
        if is_map(schema) and system == "" do
          "Answer by calling the respond tool with the structured result."
        else
          system
        end

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

      request =
        if is_map(schema) do
          Map.put(request, :tools, [
            %{
              "name" => "respond",
              "description" => "Report the final structured answer.",
              "parameters" => schema
            }
          ])
        else
          request
        end

      chunk_emit = fn delta ->
        Host.emit(host, {:node_chunk, %{node_id: node.id, delta: delta}})
      end

      case invoke.(request, chunk_emit) do
        {:ok, %{content: content} = result} ->
          outputs = %{"text" => content, "usage" => Map.get(result, :usage, %{})}

          if is_map(schema) do
            {:ok, Map.put(outputs, "output", structured_output(result))}
          else
            {:ok, outputs}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp structured_output(result) do
    from_tool =
      result
      |> Map.get(:tool_calls, [])
      |> Enum.find_value(fn
        %{name: "respond", arguments: %{} = arguments} -> arguments
        _other -> nil
      end)

    from_tool ||
      case Jason.decode(result.content || "") do
        {:ok, %{} = decoded} -> decoded
        _not_json -> %{}
      end
  end

  defp require_config(true), do: :ok
  defp require_config(false), do: {:error, "the LLM node needs a provider and model"}

  defp fetch_invoker(%Host{invoke_llm: invoke}) when is_function(invoke, 2), do: {:ok, invoke}
  defp fetch_invoker(_host), do: {:error, "this run's host cannot invoke models"}
end

defmodule Flux.Engine.Nodes.IfElse do
  @moduledoc """
  Evaluates case chains (if / elif / …) and branches on the first matching
  case's handle, or `"false"` (the else branch) when none match.

  Config: `%{"cases" => [%{"id", "logical_operator" => "and" | "or",
  "conditions" => [%{"left", "operator", "right"}]}]}`. Legacy single-case
  configs (`logical_operator`/`conditions` at the top level) behave as one
  case with handle `"true"`, preserving the original true/false contract.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @operators ~w(contains not_contains equals not_equals starts_with ends_with
                is_empty is_not_empty gt gte lt lte)

  def operators, do: @operators

  @impl true
  def run(node, pool, _host) do
    node.config
    |> cases()
    |> Enum.reduce_while({:ok, nil}, fn kase, {:ok, nil} ->
      case case_verdict(kase, pool) do
        {:ok, true} -> {:halt, {:ok, kase["id"]}}
        {:ok, false} -> {:cont, {:ok, nil}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, nil} -> {:ok, %{"result" => false, "case_id" => "false"}, "false"}
      {:ok, case_id} -> {:ok, %{"result" => true, "case_id" => case_id}, case_id}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Normalized case list (shared with the graph validator for handle
  derivation). Legacy flat configs become one case with id `"true"`.
  """
  def cases(config) do
    case config["cases"] do
      [_ | _] = cases ->
        cases
        |> Enum.with_index(1)
        |> Enum.map(fn {kase, index} ->
          %{
            "id" => to_string(kase["id"] || "case_#{index}"),
            "logical_operator" => kase["logical_operator"] || "and",
            "conditions" => List.wrap(kase["conditions"])
          }
        end)

      _legacy ->
        [
          %{
            "id" => "true",
            "logical_operator" => config["logical_operator"] || "and",
            "conditions" => List.wrap(config["conditions"])
          }
        ]
    end
  end

  defp case_verdict(kase, pool) do
    with {:ok, verdicts} <- evaluate_all(kase["conditions"], pool) do
      result =
        case {kase["logical_operator"], verdicts} do
          {_operator, []} -> false
          {"or", verdicts} -> Enum.any?(verdicts)
          {_and, verdicts} -> Enum.all?(verdicts)
        end

      {:ok, result}
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
  (interoperable `main(**inputs) -> dict` contract, plus per-block
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
  configured tools (snapshotted toolset operations) until it answers or
  `max_iterations` is hit — the guard the upstream reference lacks.

  Config: `provider_plugin_id`, `model`, `instructions`, `query`
  (template), `max_iterations` (default 5),
  `tools` ([{name, description, parameters, toolset_id, operation_id,
  deferred?}]), plus three v2 features:

    * `output_schema` — a JSON schema; when set, a synthetic `final_output`
      tool is offered and calling it terminates the loop with the
      arguments as structured `"output"`.
    * deferred tools (`"deferred" => true` on a tool) — human-in-the-loop:
      calling one ends the run with `"status" => "deferred"`, the pending
      `"deferred_tool_calls"`, and an opaque `"session_snapshot"`. Resume
      by running again with `session_snapshot` and
      `deferred_tool_results` (JSON list of `{tool_call_id, content}`)
      in the node config (typically wired from start variables).
    * part events — every iteration emits `{:agent_part, ...}` engine
      events with the upstream vocabulary (`part_start`/`part_delta` with
      `kind: thinking`, `function_tool_call`, `function_tool_result`).

  Outputs `%{"text", "output", "status", "iterations", "tool_calls"}`
  plus `"deferred_tool_calls"`/`"session_snapshot"` when deferred.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @final_output "final_output"

  @impl true
  def run(node, pool, host) do
    {plugin_id, model} = Host.resolve_llm(host, node.config)

    with :ok <- require_config(plugin_id != "" and model != ""),
         {:ok, invoke_llm} <- capability(host, :invoke_llm, 2),
         {:ok, invoke_tool} <- capability(host, :invoke_tool, 1) do
      context = %{
        node: node,
        host: host,
        plugin_id: plugin_id,
        model: model,
        tools: List.wrap(node.config["tools"]),
        output_schema: node.config["output_schema"],
        invoke_llm: invoke_llm,
        invoke_tool: invoke_tool
      }

      max_iterations = node.config["max_iterations"] || 5

      case initial_state(node, pool) do
        {:ok, messages, iteration, calls_so_far} ->
          loop(context, messages, iteration, max_iterations, calls_so_far)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Fresh run, or resume from a deferred-tool snapshot.
  defp initial_state(node, pool) do
    snapshot = Template.render(node.config["session_snapshot"], pool)

    if snapshot == "" do
      instructions = Template.render(node.config["instructions"], pool)
      query = Template.render(node.config["query"], pool)

      messages =
        if instructions == "" do
          [%{role: :user, content: query}]
        else
          [%{role: :system, content: instructions}, %{role: :user, content: query}]
        end

      {:ok, messages, 1, 0}
    else
      results_json = Template.render(node.config["deferred_tool_results"], pool)

      with {:ok, state} <- decode_snapshot(snapshot),
           {:ok, results} <- decode_results(results_json) do
        {:ok, resolve_pending(state.messages, results), state.iteration, state.tool_calls}
      end
    end
  end

  defp loop(_context, _messages, iteration, max_iterations, _calls)
       when iteration > max_iterations do
    {:error, "agent exceeded max_iterations (#{max_iterations}) without a final answer"}
  end

  defp loop(context, messages, iteration, max_iterations, calls_so_far) do
    emit_part(context, iteration, %{type: "part_start", kind: "thinking"})

    chunk_emit = fn delta ->
      Host.emit(context.host, {:node_chunk, %{node_id: context.node.id, delta: delta}})
      emit_part(context, iteration, %{type: "part_delta", kind: "thinking", delta: delta})
    end

    request = %{
      provider_plugin_id: context.plugin_id,
      model: context.model,
      messages: messages,
      params: context.node.config["params"] || %{},
      tools: tool_defs(context)
    }

    case context.invoke_llm.(request, chunk_emit) do
      {:ok, %{tool_calls: [_call | _] = tool_calls} = result} ->
        handle_tool_round(
          context,
          messages,
          result,
          tool_calls,
          iteration,
          max_iterations,
          calls_so_far
        )

      {:ok, result} ->
        {:ok, completed(result.content, nil, iteration, calls_so_far)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_tool_round(context, messages, result, tool_calls, iteration, max, calls_so_far) do
    calls_total = calls_so_far + length(tool_calls)

    case Enum.find(tool_calls, &(&1.name == @final_output)) do
      %{arguments: arguments} ->
        {:ok, completed(result.content || "", stringify(arguments), iteration, calls_total)}

      nil ->
        assistant = %{role: :assistant, content: result.content, tool_calls: tool_calls}
        {deferred, executable} = Enum.split_with(tool_calls, &deferred?(context, &1))
        tool_messages = Enum.map(executable, &execute_tool(context, &1, iteration))

        if deferred == [] do
          loop(context, messages ++ [assistant | tool_messages], iteration + 1, max, calls_total)
        else
          Enum.each(deferred, fn call ->
            emit_part(context, iteration, %{
              type: "function_tool_call",
              id: call.id,
              name: call.name,
              arguments: call.arguments,
              deferred: true
            })
          end)

          snapshot =
            encode_snapshot(
              messages ++ [assistant | tool_messages],
              iteration + 1,
              calls_total
            )

          {:ok,
           %{
             "text" => "",
             "output" => nil,
             "status" => "deferred",
             "deferred_tool_calls" =>
               Enum.map(deferred, fn call ->
                 %{"id" => call.id, "name" => call.name, "arguments" => stringify(call.arguments)}
               end),
             "session_snapshot" => snapshot,
             "iterations" => iteration,
             "tool_calls" => calls_total
           }}
        end
    end
  end

  defp completed(text, output, iterations, tool_calls) do
    %{
      "text" => text,
      "output" => output,
      "status" => "completed",
      "iterations" => iterations,
      "tool_calls" => tool_calls
    }
  end

  defp tool_defs(context) do
    defs = Enum.map(context.tools, &Map.take(&1, ["name", "description", "parameters"]))

    case context.output_schema do
      %{} = schema ->
        defs ++
          [
            %{
              "name" => @final_output,
              "description" =>
                "Call this exactly once to finish and return your final structured answer.",
              "parameters" => schema
            }
          ]

      _absent ->
        defs
    end
  end

  defp deferred?(context, call) do
    case Enum.find(context.tools, &(&1["name"] == call.name)) do
      %{"deferred" => true} -> true
      _normal_or_unknown -> false
    end
  end

  defp execute_tool(context, call, iteration) do
    emit_part(context, iteration, %{
      type: "function_tool_call",
      id: call.id,
      name: call.name,
      arguments: call.arguments
    })

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

    emit_part(context, iteration, %{
      type: "function_tool_result",
      id: call.id,
      name: call.name,
      content: content
    })

    %{role: :tool, tool_call_id: call.id, name: call.name, content: content}
  end

  defp emit_part(context, iteration, payload) do
    Host.emit(
      context.host,
      {:agent_part, Map.merge(payload, %{node_id: context.node.id, iteration: iteration})}
    )
  end

  ## Session snapshots (opaque base64 JSON; the resume contract)

  defp encode_snapshot(messages, iteration, tool_calls) do
    %{
      "messages" => Enum.map(messages, &encode_message/1),
      "iteration" => iteration,
      "tool_calls" => tool_calls
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp encode_message(%{role: :tool} = message) do
    %{
      "role" => "tool",
      "tool_call_id" => message.tool_call_id,
      "name" => message.name,
      "content" => message.content
    }
  end

  defp encode_message(%{role: role, tool_calls: tool_calls} = message) do
    %{
      "role" => to_string(role),
      "content" => message.content,
      "tool_calls" =>
        Enum.map(tool_calls, fn call ->
          %{"id" => call.id, "name" => call.name, "arguments" => stringify(call.arguments)}
        end)
    }
  end

  defp encode_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp decode_snapshot(snapshot) do
    with {:ok, json} <- Base.decode64(snapshot),
         {:ok, %{"messages" => messages} = state} <- Jason.decode(json) do
      {:ok,
       %{
         messages: Enum.map(messages, &decode_message/1),
         iteration: state["iteration"] || 1,
         tool_calls: state["tool_calls"] || 0
       }}
    else
      _invalid -> {:error, "invalid session_snapshot"}
    end
  end

  defp decode_message(%{"role" => "tool"} = message) do
    %{
      role: :tool,
      tool_call_id: message["tool_call_id"],
      name: message["name"],
      content: message["content"]
    }
  end

  defp decode_message(%{"tool_calls" => tool_calls} = message) do
    %{
      role: decode_role(message["role"]),
      content: message["content"],
      tool_calls:
        Enum.map(tool_calls, fn call ->
          %{id: call["id"], name: call["name"], arguments: call["arguments"] || %{}}
        end)
    }
  end

  defp decode_message(message) do
    %{role: decode_role(message["role"]), content: message["content"]}
  end

  defp decode_role("system"), do: :system
  defp decode_role("assistant"), do: :assistant
  defp decode_role("tool"), do: :tool
  defp decode_role(_user), do: :user

  defp decode_results(""), do: {:ok, []}

  defp decode_results(json) do
    case Jason.decode(json) do
      {:ok, results} when is_list(results) -> {:ok, results}
      _invalid -> {:error, "deferred_tool_results must be a JSON list"}
    end
  end

  # Answers every tool call that has no tool message yet with the caller's
  # supplied results (matched by tool_call_id).
  defp resolve_pending(messages, results) do
    answered =
      for %{role: :tool, tool_call_id: id} <- messages, into: MapSet.new(), do: id

    pending =
      messages
      |> Enum.flat_map(fn
        %{role: :assistant, tool_calls: calls} -> calls
        _other -> []
      end)
      |> Enum.reject(&MapSet.member?(answered, &1.id))

    tool_messages =
      Enum.map(pending, fn call ->
        content =
          Enum.find_value(results, "error: no result provided", fn result ->
            if result["tool_call_id"] == call.id or result["id"] == call.id,
              do: to_string(result["content"] || "")
          end)

        %{role: :tool, tool_call_id: call.id, name: call.name, content: content}
      end)

    messages ++ tool_messages
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

defmodule Flux.Engine.Nodes.KnowledgeRetrieval do
  @moduledoc """
  Retrieves relevant segments from a dataset through the host's
  `retrieve_knowledge` capability (hybrid semantic + keyword).

  Config: `dataset_id`, `query` (template), `top_k` (default 4).
  Outputs `%{"result" => joined text, "citations" => [%{"document",
  "content", "score"}], "count"}` — feed `result` to an LLM prompt and
  `citations` to the answer.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    dataset_id = to_string(node.config["dataset_id"] || "")

    with :ok <- require_dataset(dataset_id),
         {:ok, retrieve} <- capability(host) do
      query = Template.render(node.config["query"], pool)
      top_k = node.config["top_k"] || 4

      case retrieve.(%{dataset_id: dataset_id, query: query, top_k: top_k}) do
        {:ok, hits} ->
          citations =
            Enum.map(hits, fn hit ->
              %{
                "document" => hit.document_name,
                "content" => hit.content,
                "score" => hit.score
              }
            end)

          {:ok,
           %{
             "result" => Enum.map_join(hits, "\n\n---\n\n", & &1.content),
             "citations" => citations,
             "count" => length(hits)
           }}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp require_dataset(""), do: {:error, "the knowledge node needs a dataset"}
  defp require_dataset(_id), do: :ok

  defp capability(%Host{retrieve_knowledge: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp capability(_host), do: {:error, "this run's host cannot retrieve knowledge"}
end

defmodule Flux.Engine.Nodes.HumanInput do
  @moduledoc """
  Pauses the run for a human: returns `{:pause, prompt}` — the runner
  surfaces a paused outcome whose snapshot the embedding app persists.
  On resume, the human's answer becomes this node's `"output"`.

  Config: `prompt` (template), `options` (optional list of suggested
  answers, informational).
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @impl true
  def run(node, pool, _host) do
    {:pause,
     %{
       "prompt" => Template.render(node.config["prompt"], pool),
       "options" => node.config["options"] |> List.wrap() |> Enum.map(&to_string/1)
     }}
  end
end

defmodule Flux.Engine.Nodes.Iteration do
  @moduledoc """
  Runs another published flux once per item of a list (see
  docs/ITERATION-DESIGN.md for why iteration composes over a sub-flux
  rather than an inline scope).

  Config: `variable` (list selector; JSON strings decoded),
  `workflow_id`, `max_items` (default 50, cap 200).
  Outputs `%{"output" => [sub-run outputs...], "count" => n}`; emits
  `{:iteration_progress, %{node_id, index, total}}` per item.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @default_max_items 50
  @max_items_cap 200

  @impl true
  def run(node, pool, host) do
    workflow_id = to_string(node.config["workflow_id"] || "")

    with :ok <- require_workflow(workflow_id),
         {:ok, run_subflux} <- capability(host),
         {:ok, items} <- fetch_items(node, pool) do
      total = length(items)

      items
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
        Host.emit(
          host,
          {:iteration_progress, %{node_id: node.id, index: index, total: total}}
        )

        case run_subflux.(%{workflow_id: workflow_id, item: item, index: index}) do
          {:ok, outputs} -> {:cont, {:ok, [outputs | acc]}}
          {:error, reason} -> {:halt, {:error, "item #{index}: #{format(reason)}"}}
        end
      end)
      |> case do
        {:ok, outputs} ->
          {:ok, %{"output" => Enum.reverse(outputs), "count" => total}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_items(node, pool) do
    selector = to_string(node.config["variable"] || "")

    items =
      case Template.resolve(pool, selector) do
        list when is_list(list) ->
          list

        binary when is_binary(binary) ->
          case Jason.decode(binary) do
            {:ok, list} when is_list(list) -> list
            _not_a_list -> :error
          end

        nil ->
          []

        _other ->
          :error
      end

    case items do
      :error ->
        {:error, "#{selector} is not a list"}

      list ->
        max_items = min(node.config["max_items"] || @default_max_items, @max_items_cap)

        if length(list) > max_items do
          {:error, "the list has #{length(list)} items; max_items is #{max_items}"}
        else
          {:ok, list}
        end
    end
  end

  defp require_workflow(""), do: {:error, "the iteration node needs a sub-flux"}
  defp require_workflow(_id), do: :ok

  defp capability(%Host{run_subflux: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp capability(_host), do: {:error, "this run's host cannot run sub-fluxes"}

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end

defmodule Flux.Engine.Nodes.DocumentExtractor do
  @moduledoc """
  Extracts text from an uploaded file: `config["variable"]` resolves to a
  file id (e.g. from a start variable carrying an upload id), and the
  host's `read_document` capability returns the text.

  Outputs `%{"text", "name", "size"}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    with {:ok, read} <- capability(host) do
      file_id =
        case Template.resolve(pool, to_string(node.config["variable"] || "")) do
          nil -> Template.render(node.config["variable"], pool)
          value -> to_string(value)
        end

      case read.(%{file_id: file_id}) do
        {:ok, %{text: text} = result} ->
          {:ok,
           %{
             "text" => text,
             "name" => Map.get(result, :name, ""),
             "size" => Map.get(result, :size)
           }}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp capability(%Host{read_document: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp capability(_host), do: {:error, "this run's host cannot read documents"}
end

defmodule Flux.Engine.Nodes.QuestionClassifier do
  @moduledoc """
  LLM-backed branching: classifies the rendered `query` into one of the
  configured `classes` (`[%{"id", "name"}]`) and leaves on the matching
  class-id handle. Uses a forced `classify` tool call for structure, with
  a text-match fallback; an unclassifiable answer takes the first class.

  Config: `provider_plugin_id`/`model` (workspace default applies),
  `query`, `classes`, `instruction` (optional).
  Outputs `%{"class_id", "class_name"}` on the class-id branch.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    {plugin_id, model} = Host.resolve_llm(host, node.config)
    classes = classes(node.config)

    with :ok <- require_classes(classes),
         :ok <- require_model(plugin_id, model),
         {:ok, invoke} <- fetch_invoker(host) do
      query = Template.render(node.config["query"], pool)
      instruction = Template.render(node.config["instruction"], pool)

      catalog =
        Enum.map_join(classes, "\n", fn class -> "- #{class["id"]}: #{class["name"]}" end)

      system =
        """
        Classify the user's input into exactly one of these classes:
        #{catalog}
        #{instruction}
        Call the classify tool with the chosen class_id.\
        """

      tool = %{
        "name" => "classify",
        "description" => "Report the class the input belongs to.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "class_id" => %{"type" => "string", "enum" => Enum.map(classes, & &1["id"])}
          },
          "required" => ["class_id"]
        }
      }

      request = %{
        provider_plugin_id: plugin_id,
        model: model,
        messages: [%{role: :system, content: system}, %{role: :user, content: query}],
        params: node.config["params"] || %{},
        tools: [tool]
      }

      case invoke.(request, fn _delta -> :ok end) do
        {:ok, result} ->
          class = pick_class(result, classes)
          {:ok, %{"class_id" => class["id"], "class_name" => class["name"]}, class["id"]}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Normalized classes from a node config (shared with the graph validator)."
  def classes(config) do
    config["classes"]
    |> List.wrap()
    |> Enum.map(fn class ->
      %{
        "id" => to_string(class["id"] || ""),
        "name" => to_string(class["name"] || class["id"] || "")
      }
    end)
    |> Enum.reject(&(&1["id"] == ""))
  end

  defp pick_class(result, classes) do
    from_tool =
      result
      |> Map.get(:tool_calls, [])
      |> Enum.find_value(fn
        %{name: "classify", arguments: %{"class_id" => id}} -> find_class(classes, id)
        _other -> nil
      end)

    from_tool || from_text(result.content, classes) || List.first(classes)
  end

  defp find_class(classes, id), do: Enum.find(classes, &(&1["id"] == to_string(id)))

  defp from_text(nil, _classes), do: nil

  defp from_text(content, classes) do
    text = String.downcase(content)

    Enum.find(classes, fn class ->
      String.contains?(text, String.downcase(class["id"])) or
        String.contains?(text, String.downcase(class["name"]))
    end)
  end

  defp require_classes([]), do: {:error, "the classifier needs at least one class"}
  defp require_classes(_classes), do: :ok

  defp require_model(plugin_id, model) when plugin_id != "" and model != "", do: :ok

  defp require_model(_plugin_id, _model),
    do: {:error, "the classifier needs a provider and model"}

  defp fetch_invoker(%Host{invoke_llm: fun}) when is_function(fun, 2), do: {:ok, fun}
  defp fetch_invoker(_host), do: {:error, "this run's host cannot invoke models"}
end

defmodule Flux.Engine.Nodes.ParameterExtractor do
  @moduledoc """
  LLM-backed structured extraction: pulls the configured `parameters`
  (`[%{"name", "type", "description", "required"}]`, type
  `"string" | "number" | "bool"`) out of the rendered `query` via a
  forced `extract` tool call.

  Outputs the extracted values by name plus `"is_success"` and
  `"reason"` (why extraction failed or which required fields are missing).
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    {plugin_id, model} = Host.resolve_llm(host, node.config)
    parameters = parameters(node.config)

    with :ok <- require_parameters(parameters),
         :ok <- require_model(plugin_id, model),
         {:ok, invoke} <- fetch_invoker(host) do
      query = Template.render(node.config["query"], pool)
      instruction = Template.render(node.config["instruction"], pool)

      properties =
        Map.new(parameters, fn parameter ->
          {parameter["name"],
           %{
             "type" => json_type(parameter["type"]),
             "description" => parameter["description"] || ""
           }}
        end)

      required =
        parameters |> Enum.filter(&(&1["required"] == true)) |> Enum.map(& &1["name"])

      tool = %{
        "name" => "extract",
        "description" => "Report the extracted parameters.",
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => required
        }
      }

      system =
        """
        Extract the requested parameters from the user's input by calling
        the extract tool. Leave out anything that is not present.
        #{instruction}\
        """

      request = %{
        provider_plugin_id: plugin_id,
        model: model,
        messages: [%{role: :system, content: system}, %{role: :user, content: query}],
        params: node.config["params"] || %{},
        tools: [tool]
      }

      case invoke.(request, fn _delta -> :ok end) do
        {:ok, result} -> {:ok, build_outputs(result, parameters)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp build_outputs(result, parameters) do
    arguments =
      result
      |> Map.get(:tool_calls, [])
      |> Enum.find_value(fn
        %{name: "extract", arguments: %{} = arguments} -> arguments
        _other -> nil
      end) || decode_content(result.content)

    extracted =
      Map.new(parameters, fn parameter ->
        name = parameter["name"]
        {name, coerce(parameter["type"], Map.get(arguments, name))}
      end)

    missing =
      for parameter <- parameters,
          parameter["required"] == true,
          extracted[parameter["name"]] == nil,
          do: parameter["name"]

    status =
      cond do
        missing != [] ->
          %{"is_success" => false, "reason" => "missing: #{Enum.join(missing, ", ")}"}

        arguments == %{} ->
          %{"is_success" => false, "reason" => "no parameters extracted"}

        true ->
          %{"is_success" => true, "reason" => nil}
      end

    Map.merge(extracted, status)
  end

  defp decode_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} -> decoded
      _not_json -> %{}
    end
  end

  defp decode_content(_content), do: %{}

  defp coerce(_type, nil), do: nil
  defp coerce("number", value) when is_number(value), do: value

  defp coerce("number", value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> if trunc(number) == number, do: trunc(number), else: number
      _invalid -> nil
    end
  end

  defp coerce("bool", value) when is_boolean(value), do: value
  defp coerce("bool", value) when is_binary(value), do: value in ~w(true yes 1)
  defp coerce(_string, value) when is_binary(value), do: value
  defp coerce(_string, value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp coerce(_string, _value), do: nil

  defp json_type("number"), do: "number"
  defp json_type("bool"), do: "boolean"
  defp json_type(_string), do: "string"

  defp parameters(config) do
    config["parameters"]
    |> List.wrap()
    |> Enum.map(fn parameter ->
      %{
        "name" => to_string(parameter["name"] || ""),
        "type" => to_string(parameter["type"] || "string"),
        "description" => parameter["description"],
        "required" => parameter["required"] == true
      }
    end)
    |> Enum.reject(&(&1["name"] == ""))
  end

  defp require_parameters([]), do: {:error, "the extractor needs at least one parameter"}
  defp require_parameters(_parameters), do: :ok

  defp require_model(plugin_id, model) when plugin_id != "" and model != "", do: :ok
  defp require_model(_plugin_id, _model), do: {:error, "the extractor needs a provider and model"}

  defp fetch_invoker(%Host{invoke_llm: fun}) when is_function(fun, 2), do: {:ok, fun}
  defp fetch_invoker(_host), do: {:error, "this run's host cannot invoke models"}
end

defmodule Flux.Engine.Nodes.VariableAggregator do
  @moduledoc """
  Coalesces branch outputs: resolves each selector in `config["variables"]`
  (`["node_id.path", ...]`) in order and outputs the first non-blank value
  as `%{"output" => value}`. The standard way to join if/else branches
  back into one reference.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @impl true
  def run(node, pool, _host) do
    value =
      node.config["variables"]
      |> List.wrap()
      |> Enum.map(&Template.resolve(pool, to_string(&1)))
      |> Enum.find(&(not blank?(&1)))

    {:ok, %{"output" => value}}
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end

defmodule Flux.Engine.Nodes.VariableAssigner do
  @moduledoc """
  Writes named variables: each assignment renders `value` (template) and
  outputs it under its name; all assignments are also emitted as
  `{:conversation_var_set, %{name, value}}` events so an embedding
  chatflow can persist them across turns.

  Config: `%{"assignments" => [%{"name", "value"}]}`.
  Outputs `%{name => value, ...}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    outputs =
      node.config["assignments"]
      |> List.wrap()
      |> Enum.reduce(%{}, fn assignment, acc ->
        name = to_string(assignment["name"] || "")

        if name == "" do
          acc
        else
          value = Template.render(assignment["value"], pool)
          Host.emit(host, {:conversation_var_set, %{name: name, value: value}})
          Map.put(acc, name, value)
        end
      end)

    {:ok, outputs}
  end
end

defmodule Flux.Engine.Nodes.ListOperator do
  @moduledoc """
  Filters, sorts, and slices a list. Config:

    * `"variable"` — selector for the input list (JSON strings are decoded)
    * `"filter"` — optional `%{"operator", "value"}` applied per item
      (`contains/not_contains/eq/neq/gt/lt/not_empty`; maps are matched on
      their JSON encoding)
    * `"sort"` — `"asc" | "desc" | "none"` (default none)
    * `"limit"` — optional max items

  Outputs `%{"output" => list, "first" => first, "last" => last,
  "count" => n}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @impl true
  def run(node, pool, _host) do
    with {:ok, list} <- fetch_list(node, pool) do
      filter = node.config["filter"] || %{}

      list =
        list
        |> apply_filter(filter, Template.render(filter["value"] || "", pool))
        |> apply_sort(node.config["sort"])
        |> apply_limit(node.config["limit"])

      {:ok,
       %{
         "output" => list,
         "first" => List.first(list),
         "last" => List.last(list),
         "count" => length(list)
       }}
    end
  end

  defp fetch_list(node, pool) do
    selector = to_string(node.config["variable"] || "")

    case Template.resolve(pool, selector) do
      list when is_list(list) ->
        {:ok, list}

      binary when is_binary(binary) ->
        case Jason.decode(binary) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _not_a_list -> {:error, "#{selector} is not a list"}
        end

      nil ->
        {:ok, []}

      _other ->
        {:error, "#{selector} is not a list"}
    end
  end

  defp apply_filter(list, %{"operator" => operator}, value) when operator != "" do
    Enum.filter(list, &matches?(operator, item_text(&1), value))
  end

  defp apply_filter(list, _no_filter, _value), do: list

  defp matches?("contains", item, value), do: String.contains?(item, value)
  defp matches?("not_contains", item, value), do: not String.contains?(item, value)
  defp matches?("eq", item, value), do: item == value
  defp matches?("neq", item, value), do: item != value
  defp matches?("not_empty", item, _value), do: item != ""

  defp matches?(operator, item, value) when operator in ["gt", "lt"] do
    with {left, ""} <- Float.parse(item),
         {right, ""} <- Float.parse(value) do
      if operator == "gt", do: left > right, else: left < right
    else
      _not_numeric -> false
    end
  end

  defp matches?(_unknown, _item, _value), do: true

  defp apply_sort(list, "asc"), do: Enum.sort_by(list, &sort_key/1)
  defp apply_sort(list, "desc"), do: list |> Enum.sort_by(&sort_key/1) |> Enum.reverse()
  defp apply_sort(list, _none), do: list

  defp sort_key(item) when is_number(item), do: {0, item, ""}
  defp sort_key(item), do: {1, 0, item_text(item)}

  defp apply_limit(list, limit) when is_integer(limit) and limit > 0, do: Enum.take(list, limit)

  defp apply_limit(list, limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 -> Enum.take(list, n)
      _invalid -> list
    end
  end

  defp apply_limit(list, _none), do: list

  defp item_text(item) when is_binary(item), do: item
  defp item_text(item) when is_number(item) or is_boolean(item), do: to_string(item)
  defp item_text(item), do: Jason.encode!(item)
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
