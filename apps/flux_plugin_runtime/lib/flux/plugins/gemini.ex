defmodule Flux.Plugins.Gemini do
  @moduledoc """
  Google Gemini model provider (Generative Language API, SSE streaming).

  Authenticates with a Google AI Studio API key (aistudio.google.com/apikey);
  streaming uses `:streamGenerateContent?alt=sse`.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec}
  alias Flux.Plugins.SSE

  @base_url "https://generativelanguage.googleapis.com/v1beta"

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "gemini",
      name: "Google Gemini",
      version: "0.1.0",
      category: :model,
      description: "Gemini models via a Google AI Studio API key.",
      credential_schema: [
        %CredentialField{
          key: "api_key",
          label: "API key",
          type: :secret,
          placeholder: "AIza...",
          help: "Create one at https://aistudio.google.com/apikey (Google account required)."
        }
      ]
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(_credentials) do
    [
      %Spec{name: "gemini-2.5-pro", label: "Gemini 2.5 Pro", context_window: 1_048_576},
      %Spec{name: "gemini-2.5-flash", label: "Gemini 2.5 Flash", context_window: 1_048_576},
      %Spec{name: "gemini-2.0-flash", label: "Gemini 2.0 Flash", context_window: 1_048_576}
    ]
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    case Req.get(url: @base_url <> "/models", headers: auth(credentials)) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} when status in [400, 401, 403] -> {:error, "Invalid API key."}
      {:ok, %{status: status}} -> {:error, "Google returned HTTP #{status}."}
      {:error, reason} -> {:error, "Could not reach Google: #{inspect(reason)}"}
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    {system, messages} = split_system(request.messages)

    body =
      %{contents: Enum.map(messages, &content_for/1)}
      |> maybe_put_system(system)
      |> maybe_put_generation_config(request.params)

    acc = %{content: "", usage: %{input_tokens: 0, output_tokens: 0}, finish: :stop}

    SSE.stream_request(
      [
        url: @base_url <> "/models/#{request.model}:streamGenerateContent?alt=sse",
        json: body,
        headers: auth(credentials)
      ],
      acc,
      fn data, acc ->
        case Jason.decode(data) do
          {:ok, payload} -> handle_frame(payload, acc, emit)
          {:error, _reason} -> acc
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

  defp handle_frame(payload, acc, emit) do
    delta =
      payload
      |> get_in(["candidates", Access.at(0), "content", "parts"])
      |> List.wrap()
      |> Enum.map_join("", &(&1["text"] || ""))

    acc =
      if delta == "" do
        acc
      else
        emit.(%Chunk{delta: delta})
        %{acc | content: acc.content <> delta}
      end

    # usageMetadata is cumulative; the last frame carries the final counts.
    case payload["usageMetadata"] do
      %{} = usage ->
        %{
          acc
          | usage: %{
              input_tokens: usage["promptTokenCount"] || acc.usage.input_tokens,
              output_tokens: usage["candidatesTokenCount"] || acc.usage.output_tokens
            }
        }

      _absent ->
        acc
    end
  end

  defp content_for(%{role: role, content: content}) do
    %{role: (role == :assistant && "model") || "user", parts: [%{text: content}]}
  end

  defp split_system(messages) do
    case Enum.split_with(messages, &(&1.role == :system)) do
      {[], rest} -> {nil, rest}
      {[%{content: system} | _rest_system], rest} -> {system, rest}
    end
  end

  defp maybe_put_system(body, nil), do: body

  defp maybe_put_system(body, system),
    do: Map.put(body, :systemInstruction, %{parts: [%{text: system}]})

  defp maybe_put_generation_config(body, params) do
    config =
      %{}
      |> maybe_put(:temperature, params[:temperature])
      |> maybe_put(:topP, params[:top_p])
      |> maybe_put(:maxOutputTokens, params[:max_tokens])

    if config == %{}, do: body, else: Map.put(body, :generationConfig, config)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp auth(credentials) do
    [{"x-goog-api-key", credentials["api_key"] || ""}]
  end
end
