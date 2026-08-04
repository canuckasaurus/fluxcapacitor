defmodule Flux.Plugins.AzureOpenAI do
  @moduledoc """
  Azure OpenAI Service provider. Same chat-completions wire protocol as
  OpenAI (delegated to that plugin), but routed per-deployment —
  `{endpoint}/openai/deployments/{deployment}/…?api-version=…` with an
  `api-key` header. The "model" a flux selects is the deployment name.

  GA api-versions reject `stream_options`, so streamed responses carry
  no usage frame; token counts fall back to a bytes/4 estimate.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.ModelProvider.{Result, Spec}
  alias Flux.Plugins.SSE

  @default_api_version "2024-06-01"

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "azure_openai",
      name: "Azure OpenAI",
      version: "0.1.0",
      category: :model,
      description: "GPT deployments on Azure OpenAI Service.",
      credential_schema: [
        %CredentialField{
          key: "endpoint",
          label: "Endpoint",
          type: :url,
          placeholder: "https://my-resource.openai.azure.com",
          help: "The resource endpoint from the Azure portal."
        },
        %CredentialField{key: "api_key", label: "API key", type: :secret},
        %CredentialField{
          key: "api_version",
          label: "API version",
          type: :text,
          required: false,
          placeholder: @default_api_version
        },
        %CredentialField{
          key: "deployments",
          label: "Chat deployments",
          type: :text,
          placeholder: "gpt-4o, gpt-4o-mini|GPT-4o mini",
          help: "Comma-separated deployment names, optionally name|Label."
        },
        %CredentialField{
          key: "embedding_deployments",
          label: "Embedding deployments — optional",
          type: :text,
          required: false,
          placeholder: "text-embedding-3-small"
        }
      ]
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(credentials) do
    parse_list(credentials["deployments"], :llm) ++
      parse_list(credentials["embedding_deployments"], :text_embedding)
  end

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(credentials) do
    cond do
      endpoint(credentials) == "" ->
        {:error, "Endpoint is required."}

      to_string(credentials["api_key"] || "") == "" ->
        {:error, "API key is required."}

      parse_list(credentials["deployments"], :llm) == [] ->
        {:error, "List at least one chat deployment."}

      true ->
        probe(credentials)
    end
  end

  defp probe(credentials) do
    url = "#{endpoint(credentials)}/openai/models?api-version=#{api_version(credentials)}"

    with :ok <- Flux.SSRF.verify_url(url) do
      case Req.get(SSE.req_options(url: url, headers: auth(credentials))) do
        {:ok, %{status: status}} when status in [200, 404, 405] -> :ok
        {:ok, %{status: status}} when status in [401, 403] -> {:error, "Invalid API key."}
        {:ok, %{status: status}} -> {:error, "Azure returned HTTP #{status}."}
        {:error, reason} -> {:error, "Could not reach Azure: #{inspect(reason)}"}
      end
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(credentials, request, emit) do
    url =
      "#{endpoint(credentials)}/openai/deployments/#{URI.encode(request.model)}" <>
        "/chat/completions?api-version=#{api_version(credentials)}"

    with :ok <- Flux.SSRF.verify_url(url),
         {:ok, %Result{} = result} <-
           Flux.Plugins.OpenAI.chat_completions(url, auth(credentials), request, emit,
             include_usage: false
           ) do
      {:ok, estimate_missing_usage(result, request)}
    end
  end

  @impl Flux.Plugin.ModelProvider
  def invoke_embeddings(credentials, model, texts) do
    url =
      "#{endpoint(credentials)}/openai/deployments/#{URI.encode(model)}" <>
        "/embeddings?api-version=#{api_version(credentials)}"

    with :ok <- Flux.SSRF.verify_url(url) do
      Flux.Plugins.OpenAI.embeddings_request(url, auth(credentials), model, texts)
    end
  end

  defp estimate_missing_usage(
         %Result{usage: %{input_tokens: 0, output_tokens: 0}} = result,
         request
       ) do
    input_bytes =
      request.messages
      |> Enum.map(&byte_size(to_string(&1.content || "")))
      |> Enum.sum()

    %Result{
      result
      | usage: %{
          input_tokens: div(input_bytes, 4) + 1,
          output_tokens: div(byte_size(result.content), 4) + 1
        }
    }
  end

  defp estimate_missing_usage(result, _request), do: result

  defp parse_list(value, type) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn entry ->
      case String.split(entry, "|", parts: 2) do
        [name, label] -> %Spec{name: String.trim(name), label: String.trim(label), type: type}
        [name] -> %Spec{name: name, label: name, type: type}
      end
    end)
  end

  defp endpoint(credentials),
    do: credentials["endpoint"] |> to_string() |> String.trim() |> String.trim_trailing("/")

  defp api_version(credentials) do
    case credentials["api_version"] |> to_string() |> String.trim() do
      "" -> @default_api_version
      version -> version
    end
  end

  defp auth(credentials), do: [{"api-key", to_string(credentials["api_key"])}]
end
