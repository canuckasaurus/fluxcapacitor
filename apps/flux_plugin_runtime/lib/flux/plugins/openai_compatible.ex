defmodule Flux.Plugins.OpenAICompatible do
  @moduledoc """
  Generic provider for any OpenAI-compatible chat API — Grok/xAI,
  Together, Fireworks, Ollama, vLLM, LM Studio, proxies. The wire
  protocol delegates to the OpenAI plugin (which already honors
  `base_url` in credentials); the model catalog is user-configured.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.Spec
  alias Flux.Plugins.SSE

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "openai_compatible",
      name: "OpenAI-compatible",
      version: "0.1.0",
      category: :model,
      description: "Any OpenAI-compatible endpoint: Grok/xAI, Together, Ollama, vLLM, proxies.",
      credential_schema: [
        %CredentialField{
          key: "base_url",
          label: "Base URL",
          type: :url,
          placeholder: "https://api.x.ai/v1",
          help: "The /v1 root of the endpoint (e.g. http://localhost:11434/v1 for Ollama)."
        },
        %CredentialField{
          key: "api_key",
          label: "API key",
          type: :secret,
          required: false,
          placeholder: "xai-… (leave blank for local endpoints)"
        },
        %CredentialField{
          key: "models",
          label: "Models",
          type: :text,
          placeholder: "grok-3, grok-3-mini|Grok 3 Mini",
          help: "Comma-separated model names, optionally name|Label."
        }
      ]
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(credentials) do
    credentials
    |> Map.get("models", "")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn entry ->
      case String.split(entry, "|", parts: 2) do
        [name, label] -> %Spec{name: String.trim(name), label: String.trim(label)}
        [name] -> %Spec{name: name, label: name}
      end
    end)
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    base_url = credentials |> Map.get("base_url", "") |> to_string() |> String.trim()

    cond do
      base_url == "" ->
        {:error, "Base URL is required."}

      models(credentials) == [] ->
        {:error, "List at least one model name."}

      true ->
        probe(base_url, credentials)
    end
  end

  # Reachability probe: /models when the endpoint offers it; endpoints
  # without a model list (some proxies) still validate as long as they
  # respond at all.
  defp probe(base_url, credentials) do
    url = String.trim_trailing(base_url, "/") <> "/models"

    with :ok <- Flux.SSRF.verify_url(url) do
      case Req.get(SSE.req_options(url: url, headers: auth(credentials))) do
        {:ok, %{status: status}} when status in [200, 404, 405] -> :ok
        {:ok, %{status: status}} when status in [401, 403] -> {:error, "Invalid API key."}
        {:ok, %{status: status}} -> {:error, "Endpoint returned HTTP #{status}."}
        {:error, reason} -> {:error, "Could not reach the endpoint: #{inspect(reason)}"}
      end
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    Flux.Plugins.OpenAI.invoke_llm(credentials, request, emit)
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_embeddings(credentials, model, texts) do
    Flux.Plugins.OpenAI.invoke_embeddings(credentials, model, texts)
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_transcription(credentials, audio, opts) do
    Flux.Plugins.OpenAI.invoke_transcription(credentials, audio, opts)
  end

  defp auth(%{"api_key" => key}) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer #{key}"}]

  defp auth(_credentials), do: []
end
