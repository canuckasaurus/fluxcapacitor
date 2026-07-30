defmodule Flux.Plugins.Anthropic do
  @moduledoc "Anthropic model provider (Messages API, SSE streaming)."
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec, ToolCall}
  alias Flux.Plugins.SSE

  @base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "anthropic",
      name: "Anthropic",
      version: "0.1.0",
      category: :model,
      description: "Claude models via the Anthropic API.",
      credential_schema: [
        %CredentialField{
          key: "api_key",
          label: "API key",
          type: :secret,
          placeholder: "sk-ant-..."
        }
      ]
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(_credentials) do
    [
      %Spec{name: "claude-sonnet-5", label: "Claude Sonnet 5", context_window: 200_000},
      %Spec{name: "claude-opus-5", label: "Claude Opus 5", context_window: 200_000},
      %Spec{name: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5", context_window: 200_000}
    ]
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    case Req.get(SSE.req_options(url: @base_url <> "/models", headers: auth(credentials))) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key."}
      {:ok, %{status: status}} -> {:error, "Anthropic returned HTTP #{status}."}
      {:error, reason} -> {:error, "Could not reach Anthropic: #{inspect(reason)}"}
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    {system, messages} = split_system(request.messages)

    body =
      %{
        model: request.model,
        max_tokens: Map.get(request.params, :max_tokens, 4096),
        messages: Enum.map(messages, &encode_message/1),
        stream: true
      }
      |> then(fn body -> if system, do: Map.put(body, :system, system), else: body end)
      |> then(fn body ->
        if request.tools == [] do
          body
        else
          Map.put(body, :tools, Enum.map(request.tools, &encode_tool/1))
        end
      end)
      |> Map.merge(Map.take(request.params, [:temperature, :top_p]))

    acc = %{content: "", usage: %{input_tokens: 0, output_tokens: 0}, finish: :stop, calls: %{}}

    SSE.stream_request(
      [url: @base_url <> "/messages", json: body, headers: auth(credentials)],
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
      {:ok, %{"type" => type} = frame} -> handle_event(type, frame, acc, emit)
      _invalid -> acc
    end
  end

  defp handle_event("content_block_delta", frame, acc, emit) do
    case frame["delta"] do
      %{"text" => delta} ->
        emit.(%Chunk{delta: delta})
        %{acc | content: acc.content <> delta}

      %{"type" => "input_json_delta", "partial_json" => fragment} ->
        index = frame["index"]

        update_in(acc.calls, fn calls ->
          Map.update(calls, index, %{id: nil, name: "", json: fragment}, fn call ->
            %{call | json: call.json <> fragment}
          end)
        end)

      _other ->
        acc
    end
  end

  defp handle_event("content_block_start", frame, acc, _emit) do
    case frame["content_block"] do
      %{"type" => "tool_use", "id" => id, "name" => name} ->
        %{acc | calls: Map.put(acc.calls, frame["index"], %{id: id, name: name, json: ""})}

      _other ->
        acc
    end
  end

  defp handle_event("message_start", frame, acc, _emit) do
    case get_in(frame, ["message", "usage", "input_tokens"]) do
      n when is_integer(n) -> put_in(acc.usage.input_tokens, n)
      _absent -> acc
    end
  end

  defp handle_event("message_delta", frame, acc, _emit) do
    acc =
      case get_in(frame, ["usage", "output_tokens"]) do
        n when is_integer(n) -> put_in(acc.usage.output_tokens, n)
        _absent -> acc
      end

    case get_in(frame, ["delta", "stop_reason"]) do
      "tool_use" -> %{acc | finish: :tool_calls}
      "max_tokens" -> %{acc | finish: :length}
      _other -> acc
    end
  end

  defp handle_event(_type, _frame, acc, _emit), do: acc

  defp finalize_calls(calls) do
    calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {index, call} ->
      arguments =
        case Jason.decode(call.json) do
          {:ok, %{} = args} -> args
          _empty_or_invalid -> %{}
        end

      %ToolCall{id: call.id || "toolu_#{index}", name: call.name, arguments: arguments}
    end)
  end

  defp encode_tool(tool) do
    %{name: tool.name, description: tool.description, input_schema: tool.parameters}
  end

  defp encode_message(%{role: :tool} = message) do
    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: message.tool_call_id,
          content: message.content || ""
        }
      ]
    }
  end

  defp encode_message(%{tool_calls: [_call | _] = calls} = message) do
    text_blocks =
      case message.content do
        content when is_binary(content) and content != "" -> [%{type: "text", text: content}]
        _empty -> []
      end

    tool_blocks =
      for call <- calls do
        %{type: "tool_use", id: call.id, name: call.name, input: call.arguments}
      end

    %{role: "assistant", content: text_blocks ++ tool_blocks}
  end

  defp encode_message(message), do: %{role: message.role, content: message.content}

  defp split_system(messages) do
    case Enum.split_with(messages, &(&1.role == :system)) do
      {[], rest} -> {nil, rest}
      {[%{content: system} | _], rest} -> {system, rest}
    end
  end

  defp auth(credentials) do
    [{"x-api-key", credentials["api_key"]}, {"anthropic-version", @api_version}]
  end
end
