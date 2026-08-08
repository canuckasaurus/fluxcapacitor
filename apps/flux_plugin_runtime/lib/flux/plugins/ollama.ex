defmodule Flux.Plugins.Ollama do
  @moduledoc """
  Local models through Ollama: point it at a base URL (default
  `http://localhost:11434`) and the model list auto-discovers from
  `/api/tags` — no key, no manual catalog. Chat and embeddings ride
  Ollama's OpenAI-compatible surface (`<base>/v1`), so streaming, tools,
  and vision all work exactly like any other OpenAI-shaped provider.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.Manifest
  alias Flux.Plugin.ModelProvider.Spec
  alias Flux.Plugins.SSE

  @default_base "http://localhost:11434"

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "ollama",
      name: "Ollama",
      version: "0.1.0",
      category: :model,
      description:
        "Local models via Ollama — auto-discovers whatever `ollama pull` installed. No API " <>
          "key. Local addresses need FLUX_SSRF_ALLOW=localhost (or your Ollama host) in prod.",
      credential_schema: [
        %{
          key: "base_url",
          label: "Base URL",
          type: :string,
          required: false,
          placeholder: @default_base
        }
      ]
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(credentials) do
    url = base_url(credentials) <> "/api/tags"

    with :ok <- Flux.SSRF.verify_url(url),
         {:ok, %{status: 200, body: %{"models" => models}}} <-
           Req.get(SSE.req_options(url: url)) do
      for %{"name" => name} <- models do
        %Spec{name: name, label: name}
      end
    else
      _unreachable_or_empty -> []
    end
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    url = base_url(credentials) <> "/api/tags"

    with :ok <- Flux.SSRF.verify_url(url) do
      case Req.get(SSE.req_options(url: url)) do
        {:ok, %{status: 200, body: %{"models" => models}}} when models != [] ->
          :ok

        {:ok, %{status: 200}} ->
          {:error, "Ollama answered but has no models — `ollama pull` one first."}

        {:ok, %{status: status}} ->
          {:error, "Ollama returned HTTP #{status}."}

        {:error, reason} ->
          {:error, "Could not reach Ollama: #{inspect(reason)}"}
      end
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    Flux.Plugins.OpenAI.chat_completions(
      base_url(credentials) <> "/v1/chat/completions",
      [],
      request,
      emit
    )
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_embeddings(credentials, model, texts) do
    Flux.Plugins.OpenAI.embeddings_request(
      base_url(credentials) <> "/v1/embeddings",
      [],
      model,
      texts
    )
  end

  defp base_url(credentials) do
    case credentials["base_url"] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _default -> @default_base
    end
  end
end
