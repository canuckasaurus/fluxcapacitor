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
  forced `respond` tool call yields a structured `"output"` map,
  validated against the schema with one corrective retry (errors quoted
  back to the model) before the node fails.
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

      case invoke_with_fallback(node, host, invoke, request, chunk_emit) do
        {:ok, %{content: content} = result, model_used, fallback?} ->
          outputs = %{
            "text" => content,
            "usage" => Map.get(result, :usage, %{}),
            "model_used" => model_used,
            "fallback_used" => fallback?
          }

          if is_map(schema) do
            with_valid_output(outputs, result, schema, host, node, invoke, request, chunk_emit)
          else
            {:ok, outputs}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Structured replies validate against the schema; an invalid one gets a
  # single retry with the errors quoted back, then fails honestly.
  defp with_valid_output(outputs, result, schema, host, node, invoke, request, chunk_emit) do
    output = structured_output(result)

    case Flux.Engine.SchemaCheck.validate(output, schema) do
      :ok ->
        {:ok, Map.put(outputs, "output", output)}

      {:error, errors} ->
        Host.emit(host, {:schema_retry, %{node_id: node.id, errors: errors}})

        retry_request =
          Map.update!(request, :messages, fn messages ->
            messages ++
              [
                %{role: :assistant, content: result.content || Jason.encode!(output)},
                %{
                  role: :user,
                  content:
                    "That response did not match the required schema:\n- " <>
                      Enum.join(errors, "\n- ") <>
                      "\nCall the respond tool again with a corrected result."
                }
              ]
          end)

        with {:ok, retried} <- invoke.(retry_request, chunk_emit),
             retried_output = structured_output(retried),
             :ok <- validate_or_error(retried_output, schema) do
          usage = merge_usage(outputs["usage"], Map.get(retried, :usage, %{}))

          {:ok,
           outputs
           |> Map.put("text", retried.content || outputs["text"])
           |> Map.put("usage", usage)
           |> Map.put("output", retried_output)
           |> Map.put("schema_retried", true)}
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, _reason} -> {:error, schema_failure(errors)}
        end
    end
  end

  defp validate_or_error(output, schema) do
    case Flux.Engine.SchemaCheck.validate(output, schema) do
      :ok -> :ok
      {:error, errors} -> {:error, schema_failure(errors)}
    end
  end

  defp schema_failure(errors) do
    "structured output failed schema validation: " <> Enum.join(errors, "; ")
  end

  defp merge_usage(first, second) when is_map(first) and is_map(second) do
    Map.merge(first, second, fn _key, a, b ->
      if is_number(a) and is_number(b), do: a + b, else: b
    end)
  end

  defp merge_usage(first, _second), do: first

  # A configured fallback model gets one try when the primary errors; the
  # original error is what surfaces if both fail. The trace records which
  # model actually answered.
  defp invoke_with_fallback(node, host, invoke, request, chunk_emit) do
    primary = "#{request.provider_plugin_id}/#{request.model}"

    case invoke.(request, chunk_emit) do
      {:ok, result} ->
        {:ok, result, primary, false}

      {:error, reason} ->
        fallback_plugin = to_string(node.config["fallback_provider_plugin_id"] || "")
        fallback_model = to_string(node.config["fallback_model"] || "")

        if fallback_plugin != "" and fallback_model != "" do
          Host.emit(
            host,
            {:model_fallback,
             %{
               node_id: node.id,
               from: primary,
               to: "#{fallback_plugin}/#{fallback_model}"
             }}
          )

          fallback_request = %{
            request
            | provider_plugin_id: fallback_plugin,
              model: fallback_model
          }

          case invoke.(fallback_request, chunk_emit) do
            {:ok, result} -> {:ok, result, "#{fallback_plugin}/#{fallback_model}", true}
            {:error, _fallback_reason} -> {:error, reason}
          end
        else
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
  @moduledoc ~S"""
  Renders `config["template"]`; outputs `%{"output" => text}`.

  `config["engine"]` picks the language: `"simple"` (default —
  `{{node.key}}` interpolation) or `"jinja"` (the Jinja subset:
  filters, `{% if %}`, `{% for %}`; see `Flux.Engine.Jinja`).
  `config["template_id"]` swaps the inline text for a saved doc
  template from the workspace library (always Jinja), fetched through
  the host's `fetch_doc_template` capability.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Jinja, Template}

  @impl true
  def run(node, pool, host) do
    case to_string(node.config["template_id"] || "") do
      "" ->
        render_inline(node, pool)

      template_id ->
        with {:ok, fetch} <- capability(host),
             {:ok, content} <- fetch.(template_id) do
          render_jinja(content, pool)
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  defp render_inline(node, pool) do
    case node.config["engine"] do
      "jinja" -> render_jinja(node.config["template"], pool)
      _simple -> {:ok, %{"output" => Template.render(node.config["template"], pool)}}
    end
  end

  defp render_jinja(content, pool) do
    case Jinja.render(content, pool) do
      {:ok, output} -> {:ok, %{"output" => output}}
      {:error, message} -> {:error, "jinja: #{message}"}
    end
  end

  defp capability(%Host{fetch_doc_template: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp capability(_host), do: {:error, "this run's host cannot fetch doc templates"}
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
  `timeout_ms`, and `attachments` ([{file_id, name}] — run-output files
  placed next to the code before it runs, e.g. a trained model).
  Outputs: the returned dict's keys plus `"stdout"`, and — when the code
  saved files under `./artifacts/` — `"files"` with their stored
  download descriptors (the train half of train→serve).
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
        timeout_ms: node.config["timeout_ms"] || 30_000,
        attachments: attachments(node, pool)
      }

      case runner.(spec) do
        {:ok, %{result: %{} = result} = response} ->
          outputs = Map.new(result, fn {key, value} -> {to_string(key), value} end)
          outputs = Map.put(outputs, "stdout", Map.get(response, :stdout, ""))

          case store_artifacts(host, Map.get(response, :artifacts, [])) do
            {:ok, []} -> {:ok, outputs}
            {:ok, files} -> {:ok, Map.put(outputs, "files", files)}
            {:error, reason} -> {:error, reason}
          end

        {:ok, _bad_shape} ->
          {:error, "the code block's main() must return a dict/object"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Attachment file ids may be templated (e.g. wired from a start
  # variable holding a trained model's file id).
  defp attachments(node, pool) do
    for attachment <- List.wrap(node.config["attachments"]),
        file_id = Template.render(to_string(attachment["file_id"] || ""), pool),
        file_id != "" do
      %{"file_id" => file_id, "name" => attachment["name"]}
    end
  end

  defp store_artifacts(_host, []), do: {:ok, []}

  defp store_artifacts(%Host{store_file: store}, artifacts) when is_function(store, 1) do
    Enum.reduce_while(artifacts, {:ok, []}, fn %{name: name, binary: binary}, {:ok, stored} ->
      case store.(%{name: name, binary: binary}) do
        {:ok, file} ->
          {:cont, {:ok, stored ++ [file]}}

        {:error, reason} ->
          {:halt, {:error, "could not store artifact #{name}: #{inspect(reason)}"}}
      end
    end)
  end

  defp store_artifacts(_host, _artifacts),
    do: {:error, "this run's host cannot store code artifacts"}

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
    * `enable_drive` — offers the agent a private scratch drive for the
      run (`drive_write`/`drive_read`/`drive_list` tools). Files live in
      loop state only — sandboxed by construction, no filesystem — and
      come back in the node's `"files"` output (and survive deferred-tool
      snapshots).

  Outputs `%{"text", "output", "status", "iterations", "tool_calls",
  "files"}` plus `"deferred_tool_calls"`/`"session_snapshot"` when
  deferred.
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
        approval_tools: List.wrap(node.config["approval_tools"]),
        output_schema: node.config["output_schema"],
        invoke_llm: invoke_llm,
        invoke_tool: invoke_tool
      }

      max_iterations = node.config["max_iterations"] || 5

      case node.config["__resume_input__"] do
        %{"prompt" => %{"type" => "tool_approval"}} = resume ->
          resume_approval(context, resume, max_iterations)

        _fresh_or_deferred ->
          case initial_state(node, pool) do
            {:ok, messages, iteration, calls_so_far, drive} ->
              loop(context, messages, iteration, max_iterations, calls_so_far, drive)

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  # A tool-approval resume: the paused prompt carries the loop snapshot
  # and the pending calls; approval executes them, denial answers them
  # with a refusal — either way the loop continues in the same run.
  defp resume_approval(context, resume, max_iterations) do
    prompt = resume["prompt"]
    approved? = resume["approved"] == true

    with {:ok, state} <- decode_snapshot(prompt["state"] || "") do
      pending =
        for call <- List.wrap(prompt["pending"]) do
          %{id: call["id"], name: call["name"], arguments: call["arguments"] || %{}}
        end

      {tool_messages, drive} =
        if approved? do
          Enum.map_reduce(pending, state.drive, fn call, drive ->
            if drive_call?(context, call) do
              execute_drive(context, call, state.iteration, drive)
            else
              {execute_tool(context, call, state.iteration), drive}
            end
          end)
        else
          {Enum.map(pending, fn call ->
             %{
               role: :tool,
               tool_call_id: call.id,
               name: call.name,
               content: "The user denied this tool call. Do not retry it; adapt."
             }
           end), state.drive}
        end

      loop(
        context,
        state.messages ++ tool_messages,
        state.iteration,
        max_iterations,
        state.tool_calls,
        drive
      )
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

      {:ok, messages, 1, 0, %{}}
    else
      results_json = Template.render(node.config["deferred_tool_results"], pool)

      with {:ok, state} <- decode_snapshot(snapshot),
           {:ok, results} <- decode_results(results_json) do
        {:ok, resolve_pending(state.messages, results), state.iteration, state.tool_calls,
         state.drive}
      end
    end
  end

  defp loop(_context, _messages, iteration, max_iterations, _calls, _drive)
       when iteration > max_iterations do
    {:error, "agent exceeded max_iterations (#{max_iterations}) without a final answer"}
  end

  defp loop(context, messages, iteration, max_iterations, calls_so_far, drive) do
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
          calls_so_far,
          drive
        )

      {:ok, result} ->
        {:ok, completed(result.content, nil, iteration, calls_so_far, drive)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_tool_round(
         context,
         messages,
         result,
         tool_calls,
         iteration,
         max,
         calls_so_far,
         drive
       ) do
    calls_total = calls_so_far + length(tool_calls)

    case Enum.find(tool_calls, &(&1.name == @final_output)) do
      %{arguments: arguments} ->
        {:ok,
         completed(result.content || "", stringify(arguments), iteration, calls_total, drive)}

      nil ->
        assistant = %{role: :assistant, content: result.content, tool_calls: tool_calls}

        {needs_approval, rest} =
          Enum.split_with(tool_calls, &(&1.name in context.approval_tools))

        {deferred, executable} = Enum.split_with(rest, &deferred?(context, &1))

        {tool_messages, drive} =
          Enum.map_reduce(executable, drive, fn call, drive ->
            if drive_call?(context, call) do
              execute_drive(context, call, iteration, drive)
            else
              {execute_tool(context, call, iteration), drive}
            end
          end)

        cond do
          needs_approval != [] and deferred == [] ->
            calls_text =
              Enum.map_join(needs_approval, ", ", fn call ->
                arguments = call.arguments |> stringify() |> Jason.encode!()
                "#{call.name}(#{String.slice(arguments, 0, 200)})"
              end)

            {:pause,
             %{
               "type" => "tool_approval",
               "prompt" => "The agent wants to call: #{calls_text}. Approve?",
               "pending" =>
                 Enum.map(needs_approval, fn call ->
                   %{"id" => call.id, "name" => call.name, "arguments" => call.arguments}
                 end),
               "state" =>
                 encode_snapshot(
                   messages ++ [assistant | tool_messages],
                   iteration + 1,
                   calls_total,
                   drive
                 )
             }}

          true ->
            finish_tool_round(
              context,
              messages,
              assistant,
              tool_messages,
              deferred ++ needs_approval,
              iteration,
              max,
              calls_total,
              drive
            )
        end
    end
  end

  defp finish_tool_round(
         context,
         messages,
         assistant,
         tool_messages,
         deferred,
         iteration,
         max,
         calls_total,
         drive
       ) do
    if deferred == [] do
      loop(
        context,
        messages ++ [assistant | tool_messages],
        iteration + 1,
        max,
        calls_total,
        drive
      )
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
          calls_total,
          drive
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
         "tool_calls" => calls_total,
         "files" => drive
       }}
    end
  end

  defp completed(text, output, iterations, tool_calls, drive) do
    %{
      "text" => text,
      "output" => output,
      "status" => "completed",
      "iterations" => iterations,
      "tool_calls" => tool_calls,
      "files" => drive
    }
  end

  defp tool_defs(context) do
    defs = Enum.map(context.tools, &Map.take(&1, ["name", "description", "parameters"]))

    defs =
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

    defs ++ drive_defs(context)
  end

  ## Scratch drive (enable_drive: true)

  @drive_tools ["drive_write", "drive_read", "drive_list"]
  @max_drive_files 20
  @max_drive_bytes 64_000

  defp drive_enabled?(context), do: context.node.config["enable_drive"] == true

  defp drive_call?(context, call),
    do: call.name in @drive_tools and drive_enabled?(context)

  defp drive_defs(context) do
    if drive_enabled?(context) do
      [
        %{
          "name" => "drive_write",
          "description" =>
            "Save a file to your private scratch drive for this run " <>
              "(overwrites; max #{@max_drive_files} files, #{@max_drive_bytes} bytes each).",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string", "description" => "File name, e.g. notes.md"},
              "content" => %{"type" => "string"}
            },
            "required" => ["name", "content"]
          }
        },
        %{
          "name" => "drive_read",
          "description" => "Read a file you previously saved to the scratch drive.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"]
          }
        },
        %{
          "name" => "drive_list",
          "description" => "List the files on the scratch drive.",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]
    else
      []
    end
  end

  defp execute_drive(context, call, iteration, drive) do
    emit_part(context, iteration, %{
      type: "function_tool_call",
      id: call.id,
      name: call.name,
      arguments: call.arguments
    })

    {content, drive} = run_drive_op(call.name, stringify(call.arguments), drive)

    emit_part(context, iteration, %{
      type: "function_tool_result",
      id: call.id,
      name: call.name,
      content: content
    })

    {%{role: :tool, tool_call_id: call.id, name: call.name, content: content}, drive}
  end

  defp run_drive_op("drive_write", args, drive) do
    name = sanitize_drive_name(args["name"])
    content = to_string(args["content"] || "")

    cond do
      name == "" ->
        {"error: a file name is required", drive}

      byte_size(content) > @max_drive_bytes ->
        {"error: file exceeds #{@max_drive_bytes} bytes", drive}

      map_size(drive) >= @max_drive_files and not Map.has_key?(drive, name) ->
        {"error: the drive is full (#{@max_drive_files} files)", drive}

      true ->
        {"wrote #{name} (#{byte_size(content)} bytes)", Map.put(drive, name, content)}
    end
  end

  defp run_drive_op("drive_read", args, drive) do
    name = sanitize_drive_name(args["name"])

    case Map.fetch(drive, name) do
      {:ok, content} -> {content, drive}
      :error -> {"error: no file named #{name}", drive}
    end
  end

  defp run_drive_op("drive_list", _args, drive) do
    case Enum.sort(Map.keys(drive)) do
      [] -> {"(the drive is empty)", drive}
      names -> {Enum.map_join(names, "\n", &"#{&1} (#{byte_size(drive[&1])} bytes)"), drive}
    end
  end

  defp sanitize_drive_name(name) when is_binary(name) do
    name |> Path.basename() |> String.replace(~r/[^\w\.\-]/u, "_") |> String.slice(0, 100)
  end

  defp sanitize_drive_name(_name), do: ""

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

  defp encode_snapshot(messages, iteration, tool_calls, drive) do
    %{
      "messages" => Enum.map(messages, &encode_message/1),
      "iteration" => iteration,
      "tool_calls" => tool_calls,
      "drive" => drive
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
         tool_calls: state["tool_calls"] || 0,
         drive: (is_map(state["drive"]) && state["drive"]) || %{}
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

  Config: `dataset_id`, `query` (template), `top_k` (blank defers to the
  dataset's retrieval settings, then 4).
  Outputs `%{"result" => joined text, "citations" => [%{"document",
  "content", "score"}], "count"}` — feed `result` to an LLM prompt and
  `citations` to the answer.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    dataset_ids =
      (List.wrap(node.config["dataset_ids"]) ++ List.wrap(node.config["dataset_id"]))
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    with :ok <- require_dataset(dataset_ids),
         {:ok, retrieve} <- capability(host) do
      query = Template.render(node.config["query"], pool)
      # nil defers to per-dataset retrieval settings in the capability.
      top_k = node.config["top_k"]

      tags =
        node.config["tags"]
        |> List.wrap()
        |> Enum.map(&Template.render(to_string(&1), pool))
        |> Enum.reject(&(&1 == ""))

      # Metadata filter: values are templates too ({{start.region}}).
      metadata =
        (node.config["metadata_filter"] || %{})
        |> Enum.map(fn {key, value} -> {key, Template.render(to_string(value), pool)} end)
        |> Enum.reject(fn {_key, value} -> value == "" end)
        |> Map.new()

      case retrieve.(%{
             dataset_ids: dataset_ids,
             query: query,
             top_k: top_k,
             tags: tags,
             metadata: metadata
           }) do
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

  defp require_dataset([]), do: {:error, "the knowledge node needs a dataset"}
  defp require_dataset(_ids), do: :ok

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

defmodule Flux.Engine.Nodes.Labeling do
  @moduledoc """
  Human-in-the-loop labeling: renders its `data` fields, queues them as
  a task in a labeling project (host capability `queue_label_task`), and
  pauses the run. When someone labels the task in the console the run
  resumes with the label as this node's outputs — `"choice"`,
  `"choices"`, or `"text"` per the project's schema, plus `"output"`.

  Config: `project_id`, `data` ([{name, value-template}]).
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    project_id = to_string(node.config["project_id"] || "")

    with :ok <- (project_id != "" && :ok) || {:error, "the labeling node names no project"},
         {:ok, queue} <- capability(host) do
      data =
        node.config["data"]
        |> List.wrap()
        |> Map.new(fn field ->
          {to_string(field["name"] || ""), Template.render(field["value"], pool)}
        end)
        |> Map.delete("")

      case queue.(%{project_id: project_id, data: data, node_id: node.id}) do
        {:ok, task_id} ->
          {:pause,
           %{
             "type" => "labeling",
             "task_id" => task_id,
             "prompt" => "waiting for a human label in the labeling queue"
           }}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp capability(%Host{queue_label_task: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp capability(_host), do: {:error, "this run's host cannot queue labeling tasks"}
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

        request = %{workflow_id: workflow_id, item: item, index: index}

        request =
          if version = pinned_version(node),
            do: Map.put(request, :version, version),
            else: request

        case run_subflux.(request) do
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

  defp pinned_version(node),
    do: Flux.Engine.Nodes.SubfluxVersion.parse(node.config["subflux_version"])

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end

defmodule Flux.Engine.Nodes.Delay do
  @moduledoc """
  Waits before continuing: `seconds` (template-capable, capped at 300)
  or `until` (a template resolving to an ISO-8601 timestamp; waits at
  most the same cap). Pacing for rate-limited APIs and cooling-off
  steps — anything longer belongs on a schedule, and the error says so.
  Outputs `%{"waited_ms" => n}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.Template

  @max_wait_ms 300_000

  @impl true
  def run(node, pool, _host) do
    with {:ok, wait_ms} <- resolve_wait(node, pool) do
      Process.sleep(wait_ms)
      {:ok, %{"waited_ms" => wait_ms}}
    end
  end

  defp resolve_wait(node, pool) do
    until = Template.render(to_string(node.config["until"] || ""), pool)
    seconds = Template.render(to_string(node.config["seconds"] || ""), pool)

    cond do
      until != "" ->
        case DateTime.from_iso8601(until) do
          {:ok, target, _offset} ->
            bounded(DateTime.diff(target, DateTime.utc_now(), :millisecond))

          _invalid ->
            {:error, "until must be an ISO-8601 timestamp, got #{inspect(until)}"}
        end

      seconds != "" ->
        case Float.parse(seconds) do
          {value, _rest} when value >= 0 -> bounded(round(value * 1000))
          _invalid -> {:error, "seconds must be a number, got #{inspect(seconds)}"}
        end

      true ->
        {:error, "the delay node needs seconds or until"}
    end
  end

  defp bounded(wait_ms) when wait_ms <= 0, do: {:ok, 0}

  defp bounded(wait_ms) when wait_ms > @max_wait_ms,
    do: {:error, "delays cap at 300s — use a schedule trigger for longer waits"}

  defp bounded(wait_ms), do: {:ok, wait_ms}
end

defmodule Flux.Engine.Nodes.SubfluxVersion do
  @moduledoc false
  # Iteration and loop accept an optional `subflux_version` pin ("" or nil
  # means latest published). Accepts integers or strings like "3"/"v3".
  def parse(nil), do: nil
  def parse(version) when is_integer(version) and version > 0, do: version

  def parse(version) when is_binary(version) do
    case version |> String.trim() |> String.trim_leading("v") |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  def parse(_other), do: nil
end

defmodule Flux.Engine.Nodes.Loop do
  @moduledoc """
  Bounded while-loop: runs a published sub-flux repeatedly, feeding each
  round's outputs in as the next round's `item`, until the break
  condition matches or `max_loops` caps it. The 21st node type — the
  construct deliberately deferred in docs/ITERATION-DESIGN.md, kept
  cycle-free by composing over a sub-flux exactly like iteration.

  Config: `workflow_id`, `initial` (template; round 1's item),
  `max_loops` (default 5, cap 100), and an if_else-style break check —
  `conditions`/`logical_operator` evaluated after every round with the
  round's outputs visible as `{{<node_id>.<key>}}`.

  Outputs `%{"output" => last round outputs, "rounds", "condition_met",
  "history" => [round outputs...]}`; emits `{:loop_round, %{node_id,
  round, max}}` per round.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @default_max_loops 5
  @max_loops_cap 100

  @impl true
  def run(node, pool, host) do
    workflow_id = to_string(node.config["workflow_id"] || "")

    with :ok <- require_workflow(workflow_id),
         {:ok, run_subflux} <- capability(host) do
      max_loops = normalize_max(node.config["max_loops"])
      initial = Template.render(node.config["initial"], pool)
      loop(node, pool, host, run_subflux, workflow_id, initial, 1, max_loops, [])
    end
  end

  defp loop(node, pool, host, run_subflux, workflow_id, item, round, max, history) do
    Host.emit(host, {:loop_round, %{node_id: node.id, round: round, max: max}})

    request = %{workflow_id: workflow_id, item: item, index: round - 1}

    request =
      case Flux.Engine.Nodes.SubfluxVersion.parse(node.config["subflux_version"]) do
        nil -> request
        version -> Map.put(request, :version, version)
      end

    case run_subflux.(request) do
      {:error, reason} ->
        {:error, "round #{round}: #{format(reason)}"}

      {:ok, outputs} ->
        history = [outputs | history]

        case condition_met?(node, pool, outputs, host) do
          {:error, reason} ->
            {:error, "break condition: #{format(reason)}"}

          {:ok, true} ->
            done(outputs, round, true, history)

          {:ok, false} when round >= max ->
            done(outputs, round, false, history)

          {:ok, false} ->
            loop(node, pool, host, run_subflux, workflow_id, outputs, round + 1, max, history)
        end
    end
  end

  defp done(outputs, rounds, met, history) do
    {:ok,
     %{
       "output" => outputs,
       "rounds" => rounds,
       "condition_met" => met,
       "history" => Enum.reverse(history)
     }}
  end

  # The break check reuses the if_else evaluator: the round's outputs sit
  # under this node's id, so conditions read {{<node_id>.<key>}}. No
  # conditions → a plain bounded for-loop that always runs max rounds.
  defp condition_met?(node, pool, outputs, host) do
    case List.wrap(node.config["conditions"]) do
      [] ->
        {:ok, false}

      conditions ->
        check_pool = Map.put(pool, node.id, outputs)

        verdict_node = %{
          node
          | config: %{
              "logical_operator" => node.config["logical_operator"] || "and",
              "conditions" => conditions
            }
        }

        case Flux.Engine.Nodes.IfElse.run(verdict_node, check_pool, host) do
          {:ok, %{"result" => result}, _handle} -> {:ok, result == true}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp normalize_max(n) when is_integer(n) and n > 0, do: min(n, @max_loops_cap)

  defp normalize_max(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} when parsed > 0 -> min(parsed, @max_loops_cap)
      _invalid -> @default_max_loops
    end
  end

  defp normalize_max(_absent), do: @default_max_loops

  defp require_workflow(""), do: {:error, "the loop node needs a sub-flux"}
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

defmodule Flux.Engine.Nodes.Document do
  @moduledoc """
  Fills a Word doc template from the variable pool and stores the result
  as a run file — the assembly step of a docassemble-style flow.

  Config: `template_id` (a docx doc template), optional `output_name`
  (templated filename, defaults to the template's own name). Outputs
  `%{"file_id", "name", "url", "size"}` from the host's `store_file`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Docx, Host, Template}

  @impl true
  def run(node, pool, host) do
    format = (node.config["output_format"] == "pdf" && "pdf") || "docx"

    with {:ok, fetch, store} <- capabilities(host),
         {:ok, template_id} <- require_template(node),
         {:ok, %{binary: binary, name: template_name}} <- fetch.(template_id),
         {:ok, filled} <- Docx.render(binary, pool),
         {:ok, stored} <-
           store.(%{
             name: output_name(node, pool, template_name, format),
             binary: filled,
             format: format
           }) do
      {:ok, stored}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp capabilities(%Host{fetch_docx_template: fetch, store_file: store})
       when is_function(fetch, 1) and is_function(store, 1),
       do: {:ok, fetch, store}

  defp capabilities(_host), do: {:error, "this run's host cannot fill documents"}

  defp require_template(node) do
    case to_string(node.config["template_id"] || "") do
      "" -> {:error, "the document node needs a doc template"}
      template_id -> {:ok, template_id}
    end
  end

  defp output_name(node, pool, template_name, format) do
    name =
      case to_string(node.config["output_name"] || "") do
        "" -> template_name
        templated -> Template.render(templated, pool)
      end

    name =
      name
      |> String.trim()
      |> String.replace(~r/[^\w\.\- ]/u, "_")
      |> String.replace(~r/\.(docx|pdf)$/i, "")

    name <> "." <> format
  end
end

defmodule Flux.Engine.Nodes.FileOutput do
  @moduledoc """
  Writes templated content to a downloadable run file — HTML, PDF,
  Markdown, plain text, CSV, or JSON. The report-writer counterpart of
  the document node: no Word template required, just content from the
  variable pool.

  Config: `format` (html | pdf | markdown | text | csv | json),
  `content` (templated), optional `output_name` (templated filename
  stem). HTML and PDF content is wrapped in a minimal document when it
  isn't a full page already; PDF conversion happens host-side (the same
  Gotenberg converter the document node uses). Outputs
  `%{"file_id", "name", "url", "size", "format"}`.
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @formats %{
    "html" => %{ext: "html", store: "html"},
    "pdf" => %{ext: "pdf", store: "html_pdf"},
    "markdown" => %{ext: "md", store: "raw"},
    "text" => %{ext: "txt", store: "raw"},
    "csv" => %{ext: "csv", store: "raw"},
    "json" => %{ext: "json", store: "raw"}
  }

  @impl true
  def run(node, pool, host) do
    format = to_string(node.config["format"] || "html")

    with {:ok, store} <- capability(host),
         {:ok, spec} <- resolve_format(format),
         {:ok, content} <- require_content(node, pool),
         {:ok, stored} <-
           store.(%{
             name: output_name(node, pool, spec.ext),
             binary: prepare(content, format),
             format: spec.store
           }) do
      {:ok, Map.put(stored, "format", format)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp capability(%Host{store_file: store}) when is_function(store, 1), do: {:ok, store}
  defp capability(_host), do: {:error, "this run's host cannot store files"}

  defp resolve_format(format) do
    case @formats[format] do
      nil -> {:error, "unknown output format #{inspect(format)}"}
      spec -> {:ok, spec}
    end
  end

  defp require_content(node, pool) do
    case Template.render(to_string(node.config["content"] || ""), pool) do
      "" -> {:error, "the file output node rendered empty content"}
      content -> {:ok, content}
    end
  end

  # HTML-bound content becomes a full page unless it already is one.
  defp prepare(content, format) when format in ["html", "pdf"] do
    if content =~ ~r/<html[\s>]/i do
      content
    else
      """
      <!DOCTYPE html>
      <html>
      <head>
      <meta charset="utf-8"/>
      <style>
      body { font-family: Georgia, serif; max-width: 46em; margin: 3em auto;
             line-height: 1.5; color: #1a1a1a; padding: 0 1em; }
      table { border-collapse: collapse; } td, th { border: 1px solid #999;
             padding: 0.3em 0.6em; }
      </style>
      </head>
      <body>
      #{content}
      </body>
      </html>
      """
    end
  end

  defp prepare(content, _format), do: content

  defp output_name(node, pool, ext) do
    name =
      case to_string(node.config["output_name"] || "") do
        "" -> "output"
        templated -> Template.render(templated, pool)
      end

    name =
      name
      |> String.trim()
      |> String.replace(~r/[^\w\.\- ]/u, "_")
      |> String.replace(~r/\.(html|pdf|md|txt|csv|json)$/i, "")

    ((name == "" && "output") || name) <> "." <> ext
  end
end

defmodule Flux.Engine.Nodes.Interview do
  @moduledoc """
  Pauses the run and asks a stored question set as one form — the
  multi-field sibling of human_input. The questions snapshot into the
  pause payload, so the form survives definition edits mid-pause; on
  resume the validated answers become this node's outputs (one key per
  question, plus `"output"` with the whole map).

  Config: `interview_id` (required), `intro` (templated override of the
  interview's own intro).
  """
  @behaviour Flux.Engine.Node

  alias Flux.Engine.{Host, Template}

  @impl true
  def run(node, pool, host) do
    with {:ok, fetch} <- capability(host),
         {:ok, interview_id} <- require_interview(node),
         {:ok, interview} <- fetch.(interview_id) do
      intro =
        case to_string(node.config["intro"] || "") do
          "" -> interview["intro"] || ""
          override -> override
        end

      {:pause,
       %{
         "prompt" => Template.render(intro, pool),
         "interview" => interview["name"],
         "questions" => interview["questions"],
         "options" => []
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp capability(%Host{fetch_interview: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp capability(_host), do: {:error, "this run's host cannot load interviews"}

  defp require_interview(node) do
    case to_string(node.config["interview_id"] || "") do
      "" -> {:error, "the interview node needs an interview"}
      interview_id -> {:ok, interview_id}
    end
  end
end
