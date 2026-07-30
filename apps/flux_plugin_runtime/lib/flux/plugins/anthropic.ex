defmodule Flux.Plugins.Anthropic do
  @moduledoc "Anthropic model provider (Messages API, SSE streaming)."
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec}
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
        messages: Enum.map(messages, &%{role: &1.role, content: &1.content}),
        stream: true
      }
      |> then(fn body -> if system, do: Map.put(body, :system, system), else: body end)
      |> Map.merge(Map.take(request.params, [:temperature, :top_p]))

    acc = %{content: "", usage: %{input_tokens: 0, output_tokens: 0}, finish: :stop}

    SSE.stream_request(
      [url: @base_url <> "/messages", json: body, headers: auth(credentials)],
      acc,
      fn data, acc ->
        case Jason.decode(data) do
          {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => delta}}} ->
            emit.(%Chunk{delta: delta})
            %{acc | content: acc.content <> delta}

          {:ok, %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => n}}}} ->
            put_in(acc.usage.input_tokens, n)

          {:ok, %{"type" => "message_delta", "usage" => %{"output_tokens" => n}}} ->
            put_in(acc.usage.output_tokens, n)

          _ ->
            acc
        end
      end
    )
    |> case do
      {:ok, acc} ->
        {:ok, %Result{content: acc.content, finish_reason: acc.finish, usage: acc.usage}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
