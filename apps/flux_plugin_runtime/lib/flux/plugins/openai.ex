defmodule Flux.Plugins.OpenAI do
  @moduledoc "OpenAI model provider (chat completions, SSE streaming)."
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec, ToolCall}
  alias Flux.Plugins.SSE

  @base_url "https://api.openai.com/v1"

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "openai",
      name: "OpenAI",
      version: "0.1.0",
      category: :model,
      description: "GPT models via the OpenAI API.",
      credential_schema: [
        %CredentialField{key: "api_key", label: "API key", type: :secret, placeholder: "sk-..."},
        %CredentialField{
          key: "base_url",
          label: "Base URL",
          type: :url,
          required: false,
          placeholder: @base_url,
          help: "Override for Azure-compatible or proxy endpoints."
        }
      ]
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(_credentials) do
    [
      %Spec{name: "gpt-4o", label: "GPT-4o", context_window: 128_000},
      %Spec{name: "gpt-4o-mini", label: "GPT-4o mini", context_window: 128_000},
      %Spec{name: "gpt-4.1", label: "GPT-4.1", context_window: 1_000_000},
      %Spec{name: "o3-mini", label: "o3-mini", context_window: 200_000},
      %Spec{
        name: "text-embedding-3-small",
        label: "text-embedding-3-small",
        type: :text_embedding
      },
      %Spec{
        name: "text-embedding-3-large",
        label: "text-embedding-3-large",
        type: :text_embedding
      }
    ]
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_embeddings(credentials, model, texts) do
    embeddings_request(base_url(credentials) <> "/embeddings", auth(credentials), model, texts)
  end

  @doc """
  One OpenAI-shaped embeddings call against an arbitrary URL/auth —
  shared with the Azure plugin, whose endpoints differ only in routing.
  """
  def embeddings_request(url, headers, model, texts) do
    with :ok <- Flux.SSRF.verify_url(url),
         {:ok, %{status: 200, body: body}} <-
           Req.post(
             SSE.req_options(
               url: url,
               json: %{model: model, input: texts},
               headers: headers
             )
           ) do
      vectors =
        body["data"]
        |> List.wrap()
        |> Enum.sort_by(& &1["index"])
        |> Enum.map(& &1["embedding"])

      {:ok,
       %{
         vectors: vectors,
         usage: %{input_tokens: get_in(body, ["usage", "prompt_tokens"]) || 0}
       }}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    url = base_url(credentials) <> "/models"

    with :ok <- Flux.SSRF.verify_url(url) do
      Req.get(SSE.req_options(url: url, headers: auth(credentials)))
    end
    |> case do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key."}
      {:ok, %{status: status}} -> {:error, "OpenAI returned HTTP #{status}."}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "Could not reach OpenAI: #{inspect(reason)}"}
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    chat_completions(
      base_url(credentials) <> "/chat/completions",
      auth(credentials),
      request,
      emit
    )
  end

  @doc """
  One streaming chat-completions call against an arbitrary URL/auth —
  shared with Azure, which routes per-deployment and rejects
  `stream_options` on GA api-versions (`include_usage: false`).
  """
  def chat_completions(url, headers, request, emit, opts \\ []) do
    body = %{
      model: request.model,
      messages: Enum.map(request.messages, &encode_message/1),
      stream: true
    }

    body =
      if Keyword.get(opts, :include_usage, true) do
        Map.put(body, :stream_options, %{include_usage: true})
      else
        body
      end

    body =
      if request.tools == [] do
        body
      else
        Map.put(body, :tools, Enum.map(request.tools, &encode_tool/1))
      end

    body = Map.merge(body, Map.take(request.params, [:temperature, :max_tokens, :top_p]))

    acc = %{content: "", usage: %{input_tokens: 0, output_tokens: 0}, finish: :stop, calls: %{}}

    SSE.stream_request(
      [url: url, json: body, headers: headers],
      acc,
      fn data, acc -> handle_frame(data, acc, emit) end
    )
    |> case do
      {:ok, acc} ->
        {:ok,
         %Result{
           content: acc.content,
           finish_reason: acc.finish,
           usage: acc.usage,
           tool_calls: finalize_calls(acc.calls)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_frame(data, acc, emit) do
    case Jason.decode(data) do
      {:ok, %{"choices" => [%{"delta" => delta} = choice | _]} = frame} ->
        acc
        |> handle_content(delta, emit)
        |> handle_tool_deltas(delta)
        |> handle_finish(choice)
        |> handle_usage(frame)

      {:ok, %{"usage" => _usage} = frame} ->
        handle_usage(acc, frame)

      _other ->
        acc
    end
  end

  defp handle_content(acc, %{"content" => delta}, emit)
       when is_binary(delta) and delta != "" do
    emit.(%Chunk{delta: delta})
    %{acc | content: acc.content <> delta}
  end

  defp handle_content(acc, _delta, _emit), do: acc

  # Streamed tool calls arrive as fragments keyed by index: id/name once,
  # then argument-JSON pieces to concatenate.
  defp handle_tool_deltas(acc, %{"tool_calls" => deltas}) when is_list(deltas) do
    calls =
      Enum.reduce(deltas, acc.calls, fn delta, calls ->
        index = delta["index"] || 0
        call = Map.get(calls, index, %{id: nil, name: "", args: ""})

        call = %{
          id: call.id || delta["id"],
          name: call.name <> (get_in(delta, ["function", "name"]) || ""),
          args: call.args <> (get_in(delta, ["function", "arguments"]) || "")
        }

        Map.put(calls, index, call)
      end)

    %{acc | calls: calls}
  end

  defp handle_tool_deltas(acc, _delta), do: acc

  defp handle_finish(acc, %{"finish_reason" => "tool_calls"}), do: %{acc | finish: :tool_calls}
  defp handle_finish(acc, %{"finish_reason" => "length"}), do: %{acc | finish: :length}
  defp handle_finish(acc, _choice), do: acc

  defp handle_usage(acc, %{"usage" => %{"prompt_tokens" => input, "completion_tokens" => output}})
       when is_integer(input) do
    %{acc | usage: %{input_tokens: input, output_tokens: output}}
  end

  defp handle_usage(acc, _frame), do: acc

  defp finalize_calls(calls) do
    calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {index, call} ->
      %ToolCall{
        id: call.id || "call_#{index}",
        name: call.name,
        arguments: decode_args(call.args)
      }
    end)
  end

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, %{} = args} -> args
      _invalid -> %{}
    end
  end

  defp encode_tool(tool) do
    %{
      type: "function",
      function: %{name: tool.name, description: tool.description, parameters: tool.parameters}
    }
  end

  defp encode_message(%{role: :tool} = message) do
    %{role: "tool", tool_call_id: message.tool_call_id, content: message.content || ""}
  end

  defp encode_message(%{tool_calls: [_call | _] = calls} = message) do
    %{
      role: "assistant",
      content: message.content,
      tool_calls:
        for call <- calls do
          %{
            id: call.id,
            type: "function",
            function: %{name: call.name, arguments: Jason.encode!(call.arguments)}
          }
        end
    }
  end

  # Messages may carry `images: [%{data: base64, media_type: mime}]`.
  defp encode_message(%{images: [_image | _] = images} = message) do
    %{
      role: message.role,
      content: [
        %{type: "text", text: message.content || ""}
        | for image <- images do
            %{
              type: "image_url",
              image_url: %{url: "data:#{image.media_type};base64,#{image.data}"}
            }
          end
      ]
    }
  end

  defp encode_message(message), do: %{role: message.role, content: message.content}

  defp base_url(credentials) do
    case credentials["base_url"] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @base_url
    end
  end

  defp auth(credentials), do: [{"authorization", "Bearer #{credentials["api_key"]}"}]
end
