defmodule FluxWeb.V1.OpenAIController do
  @moduledoc """
  OpenAI-compatible surface: `POST /v1/chat/completions` with an `app-`
  bearer token maps onto that chat app — swap the base URL and any
  OpenAI SDK talks to FluxCapacitor. Stateless by design (the caller
  supplies the whole history, nothing is persisted); the request's
  `model` field is ignored — the app decides the model. Streaming uses
  OpenAI's `chat.completion.chunk` frames ending in `data: [DONE]`.
  """
  use FluxWeb, :controller

  alias Flux.Chat

  @stream_timeout :timer.minutes(5)

  def create(conn, params) do
    app = conn.assigns[:service_app]

    cond do
      app == nil ->
        openai_error(conn, 401, "This endpoint needs an app- API token.", "invalid_request_error")

      Chat.quota_exceeded?(app) ->
        openai_error(conn, 429, "The app's daily token limit is spent.", "rate_limit_error")

      true ->
        with {:ok, messages} <- normalize_messages(params["messages"]),
             {:ok, tools} <- normalize_tools(params["tools"], app),
             :ok <- guard_input(app, messages) do
          respond(conn, app, messages, params["stream"] == true, tools)
        else
          {:error, :bad_messages} ->
            openai_error(
              conn,
              400,
              "messages must be a non-empty array.",
              "invalid_request_error"
            )

          {:error, :tools_need_direct_model} ->
            openai_error(
              conn,
              400,
              "Tool calling needs a direct-model app — chatflow apps run their own tools.",
              "invalid_request_error"
            )

          {:error, :bad_tools} ->
            openai_error(
              conn,
              400,
              "tools must be an array of function definitions.",
              "invalid_request_error"
            )

          {:error, :guardrail} ->
            openai_error(conn, 400, "This content isn't allowed here.", "invalid_request_error")
        end
    end
  end

  @doc """
  OpenAI-compatible model listing: `GET /v1/models` with any service
  token — every model the workspace's configured providers offer, so
  SDKs and gateways autodiscover. With an `app-` token the app's own
  bound model leads the list.
  """
  def models(conn, _params) do
    scope = conn.assigns[:service_scope]
    app = conn.assigns[:service_app]

    provider_entries =
      for %{plugin_id: plugin_id, model: model} <- Flux.Providers.available_models(scope) do
        %{
          "id" => model.name,
          "object" => "model",
          "owned_by" => plugin_id
        }
      end

    app_entries =
      case app do
        %{model: model, provider_plugin_id: plugin_id}
        when is_binary(model) and model != "" ->
          [%{"id" => model, "object" => "model", "owned_by" => plugin_id}]

        _chatflow_or_none ->
          []
      end

    data = Enum.uniq_by(app_entries ++ provider_entries, & &1["id"])

    json(conn, %{"object" => "list", "data" => data})
  end

  @doc """
  OpenAI-compatible embeddings: `POST /v1/embeddings` with any service
  token. The `model` field names a configured embedding model; `input`
  is a string or array of strings.
  """
  def embeddings(conn, params) do
    scope = conn.assigns[:service_scope]
    inputs = params["input"] |> List.wrap() |> Enum.map(&to_string/1)
    model_name = to_string(params["model"] || "")

    embedding_entry =
      Enum.find(Flux.Providers.available_models(scope), fn entry ->
        entry.model.type == :text_embedding and entry.model.name == model_name
      end)

    cond do
      inputs == [] or Enum.all?(inputs, &(&1 == "")) ->
        openai_error(
          conn,
          400,
          "input must be a non-empty string or array.",
          "invalid_request_error"
        )

      embedding_entry == nil ->
        openai_error(
          conn,
          404,
          "No configured embedding model named #{inspect(model_name)}.",
          "invalid_request_error"
        )

      true ->
        workspace_id = Flux.Accounts.Scope.workspace_id(scope)

        case Flux.Providers.embed(workspace_id, embedding_entry.plugin_id, model_name, inputs) do
          {:ok, %{vectors: vectors, usage: usage}} ->
            data =
              vectors
              |> Enum.with_index()
              |> Enum.map(fn {vector, index} ->
                %{"object" => "embedding", "index" => index, "embedding" => vector}
              end)

            tokens = usage[:input_tokens] || 0

            json(conn, %{
              "object" => "list",
              "data" => data,
              "model" => model_name,
              "usage" => %{"prompt_tokens" => tokens, "total_tokens" => tokens}
            })

          {:error, reason} ->
            openai_error(conn, 502, "The provider errored: #{inspect(reason)}", "api_error")
        end
    end
  end

  # Tools only reach direct-model apps; the chatflow bridge runs its
  # own tools inside the flux.
  defp invoke_completion(%{mode: :advanced_chat} = app, messages, emit, _tools),
    do: Chat.stateless_chatflow_completion(app, messages, emit)

  defp invoke_completion(app, messages, emit, tools),
    do: Chat.stateless_completion(app, messages, emit, tools: tools)

  ## Blocking

  defp respond(conn, app, messages, false, tools) do
    case invoke_completion(app, messages, fn _chunk -> :ok end, tools) do
      {:ok, result, model_used} ->
        json(conn, %{
          "id" => completion_id(),
          "object" => "chat.completion",
          "created" => System.system_time(:second),
          "model" => model_used,
          "choices" => [choice(result)],
          "usage" => usage(result)
        })

      {:error, reason} ->
        openai_error(conn, 502, "The model errored: #{inspect(reason)}", "api_error")
    end
  end

  ## Streaming

  defp respond(conn, app, messages, true, tools) do
    parent = self()
    id = completion_id()
    created = System.system_time(:second)

    Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
      emit = fn %{delta: delta} -> send(parent, {:delta, delta}) end

      case invoke_completion(app, messages, emit, tools) do
        {:ok, result, model_used} -> send(parent, {:finished, result, model_used})
        {:error, reason} -> send(parent, {:failed, reason})
      end
    end)

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> stream_loop(id, created, app.model)
  end

  defp stream_loop(conn, id, created, model) do
    receive do
      {:delta, delta} ->
        case sse(conn, chunk_frame(id, created, model, %{"content" => delta}, nil)) do
          {:ok, conn} -> stream_loop(conn, id, created, model)
          {:error, _closed} -> conn
        end

      {:finished, result, model_used} ->
        conn =
          case Map.get(result, :tool_calls, []) do
            [] ->
              {_, conn} =
                sse(conn, chunk_frame(id, created, model_used, %{}, "stop", usage(result)))

              conn

            calls ->
              # Tool calls arrive whole in one delta (not argument
              # fragments) — SDKs accumulate deltas, so a single
              # complete one parses fine.
              delta = %{"role" => "assistant", "tool_calls" => encode_tool_calls(calls)}
              {_, conn} = sse(conn, chunk_frame(id, created, model_used, delta, nil))

              {_, conn} =
                sse(conn, chunk_frame(id, created, model_used, %{}, "tool_calls", usage(result)))

              conn
          end

        {_, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {:failed, reason} ->
        {_, conn} =
          sse(conn, %{
            "error" => %{
              "message" => "The model errored: #{inspect(reason)}",
              "type" => "api_error"
            }
          })

        conn
    after
      @stream_timeout ->
        {_, conn} = chunk(conn, "data: [DONE]\n\n")
        conn
    end
  end

  defp chunk_frame(id, created, model, delta, finish_reason, usage \\ nil) do
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
    |> then(fn frame -> (usage && Map.put(frame, "usage", usage)) || frame end)
  end

  defp sse(conn, payload), do: chunk(conn, "data: " <> Jason.encode!(payload) <> "\n\n")

  defp choice(result) do
    case Map.get(result, :tool_calls, []) do
      [] ->
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => result.content},
          "finish_reason" => "stop"
        }

      calls ->
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => presence(result.content),
            "tool_calls" => encode_tool_calls(calls)
          },
          "finish_reason" => "tool_calls"
        }
    end
  end

  defp encode_tool_calls(calls) do
    for call <- calls do
      %{
        "id" => call.id || "call_" <> Base.url_encode64(:crypto.strong_rand_bytes(9)),
        "type" => "function",
        "function" => %{
          "name" => call.name,
          "arguments" => Jason.encode!(call.arguments || %{})
        }
      }
    end
  end

  defp presence(""), do: nil
  defp presence(content), do: content

  ## Request plumbing

  defp normalize_messages(messages) when is_list(messages) and messages != [] do
    normalized =
      messages
      |> Enum.map(&normalize_message/1)
      |> Enum.reject(&is_nil/1)

    if normalized == [], do: {:error, :bad_messages}, else: {:ok, normalized}
  end

  defp normalize_messages(_other), do: {:error, :bad_messages}

  # Tool results feed the follow-up round of a function-calling loop.
  defp normalize_message(%{"role" => "tool", "tool_call_id" => call_id} = message) do
    %{
      role: :tool,
      tool_call_id: to_string(call_id),
      name: message["name"],
      content: content_text(message["content"]) || ""
    }
  end

  # Assistant turns replaying earlier tool_calls (arguments arrive as
  # JSON strings on the wire; the plugins want maps).
  defp normalize_message(%{"role" => "assistant", "tool_calls" => [_call | _] = calls} = message) do
    %{
      role: :assistant,
      content: content_text(message["content"]) || "",
      tool_calls:
        for %{"function" => function} = call <- calls do
          %Flux.Plugin.ModelProvider.ToolCall{
            id: call["id"],
            name: function["name"],
            arguments:
              case Jason.decode(to_string(function["arguments"] || "{}")) do
                {:ok, %{} = arguments} -> arguments
                _invalid -> %{}
              end
          }
        end
    }
  end

  defp normalize_message(%{"role" => role, "content" => content})
       when role in ["system", "user", "assistant"] do
    case content_text(content) do
      text when is_binary(text) -> %{role: String.to_existing_atom(role), content: text}
      _no_text -> nil
    end
  end

  defp normalize_message(_other), do: nil

  # OpenAI tool definitions → the plugin layer's ToolDef structs.
  defp normalize_tools(nil, _app), do: {:ok, []}
  defp normalize_tools([], _app), do: {:ok, []}

  defp normalize_tools([_tool | _] = tools, %{mode: :advanced_chat}) when is_list(tools),
    do: {:error, :tools_need_direct_model}

  defp normalize_tools(tools, _app) when is_list(tools) do
    normalized =
      for %{"type" => "function", "function" => %{"name" => name} = function} <- tools do
        %Flux.Plugin.ModelProvider.ToolDef{
          name: name,
          description: function["description"] || "",
          parameters: function["parameters"] || %{"type" => "object", "properties" => %{}}
        }
      end

    if length(normalized) == length(tools), do: {:ok, normalized}, else: {:error, :bad_tools}
  end

  defp normalize_tools(_other, _app), do: {:error, :bad_tools}

  # Content is a string, or OpenAI content-part arrays (text parts kept).
  defp content_text(content) when is_binary(content), do: content

  defp content_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp content_text(_other), do: nil

  defp guard_input(app, messages) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find_value("", fn message ->
        message.role == :user && message.content
      end)

    Flux.Guardrails.check_input(app.workspace_id, last_user, "chat input (#{app.name})")
  end

  defp usage(result) do
    input = get_in_usage(result, :input_tokens)
    output = get_in_usage(result, :output_tokens)

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp get_in_usage(%{usage: usage}, key) when is_map(usage),
    do: Map.get(usage, key) || Map.get(usage, to_string(key)) || 0

  defp get_in_usage(_result, _key), do: 0

  defp completion_id do
    "chatcmpl-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp openai_error(conn, status, message, type) do
    conn
    |> put_status(status)
    |> json(%{"error" => %{"message" => message, "type" => type, "code" => nil}})
  end
end
