defmodule Flux.Plugins.OpenAI do
  @moduledoc "OpenAI model provider (chat completions, SSE streaming)."
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec}
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
      %Spec{name: "o3-mini", label: "o3-mini", context_window: 200_000}
    ]
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    case Req.get(url: base_url(credentials) <> "/models", headers: auth(credentials)) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key."}
      {:ok, %{status: status}} -> {:error, "OpenAI returned HTTP #{status}."}
      {:error, reason} -> {:error, "Could not reach OpenAI: #{inspect(reason)}"}
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    body = %{
      model: request.model,
      messages: Enum.map(request.messages, &%{role: &1.role, content: &1.content}),
      stream: true,
      stream_options: %{include_usage: true}
    }

    body = Map.merge(body, Map.take(request.params, [:temperature, :max_tokens, :top_p]))

    acc = %{content: "", usage: %{input_tokens: 0, output_tokens: 0}, finish: :stop}

    SSE.stream_request(
      [url: base_url(credentials) <> "/chat/completions", json: body, headers: auth(credentials)],
      acc,
      fn data, acc ->
        case Jason.decode(data) do
          {:ok, %{"choices" => [%{"delta" => %{"content" => delta}} | _]}}
          when is_binary(delta) and delta != "" ->
            emit.(%Chunk{delta: delta})
            %{acc | content: acc.content <> delta}

          {:ok, %{"usage" => %{"prompt_tokens" => input, "completion_tokens" => output}}}
          when is_integer(input) ->
            %{acc | usage: %{input_tokens: input, output_tokens: output}}

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

  defp base_url(credentials) do
    case credentials["base_url"] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @base_url
    end
  end

  defp auth(credentials), do: [{"authorization", "Bearer #{credentials["api_key"]}"}]
end
