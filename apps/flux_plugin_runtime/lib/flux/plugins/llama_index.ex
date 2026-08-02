defmodule Flux.Plugins.LlamaIndex do
  @moduledoc """
  Built-in tool plugin for LlamaIndex deployments: retrieval against
  LlamaCloud managed indexes (pipelines) and function-style calls into
  llama_deploy workflow services. Installed per workspace, the
  operations appear as `plugin:llama_index` functions in tool and agent
  nodes — a flux can retrieve from the firm's existing indexes or invoke
  a deployed LlamaIndex workflow mid-run.

  Works against `https://api.cloud.llamaindex.ai` (LlamaCloud) or any
  self-hosted llama_deploy / LlamaIndex server exposing the same routes.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Tool

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.Tool.Operation
  alias Flux.Plugins.SSE

  @default_base "https://api.cloud.llamaindex.ai"
  @max_body_bytes 5_000_000

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "llama_index",
      name: "LlamaIndex",
      version: "0.1.0",
      category: :tool,
      capabilities: [:tool],
      description:
        "Retrieve from LlamaCloud managed indexes and call llama_deploy " <>
          "workflow services as functions inside a flux.",
      credential_schema: [
        %CredentialField{
          key: "base_url",
          label: "Base URL",
          type: :url,
          placeholder: @default_base
        },
        %CredentialField{
          key: "api_key",
          label: "API key",
          type: :secret,
          placeholder: "llx-..."
        },
        %CredentialField{
          key: "pipeline_id",
          label: "Default pipeline (index) id — optional",
          type: :text,
          placeholder: "leave blank to pass per call"
        }
      ]
    }
  end

  @doc """
  Credential validation: the pipelines listing must answer (LlamaCloud),
  falling back to the llama_deploy deployments listing for self-hosted
  servers that don't serve the LlamaCloud API.
  """
  def validate_credentials(credentials) do
    case get(credentials, "/api/v1/pipelines") do
      {:ok, _body} ->
        :ok

      {:error, "HTTP 404" <> _rest} ->
        case get(credentials, "/deployments") do
          {:ok, _body} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Flux.Plugin.Tool
  def operations(_credentials) do
    [
      %Operation{
        id: "retrieve",
        name: "retrieve",
        description:
          "Retrieve the most relevant chunks from a LlamaIndex managed " <>
            "index (pipeline). Returns text chunks with scores.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "The retrieval query."},
            "pipeline_id" => %{
              "type" => "string",
              "description" => "Pipeline (index) id; the credential default when omitted."
            },
            "top_k" => %{
              "type" => "integer",
              "description" => "How many chunks to return (default 5)."
            }
          },
          "required" => ["query"]
        }
      },
      %Operation{
        id: "run_workflow",
        name: "run_workflow",
        description:
          "Run a deployed llama_deploy workflow service as a function " <>
            "and return its result.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "deployment" => %{
              "type" => "string",
              "description" => "The llama_deploy deployment name."
            },
            "input" => %{
              "type" => "string",
              "description" => "The input passed to the workflow."
            }
          },
          "required" => ["deployment", "input"]
        }
      },
      %Operation{
        id: "list_pipelines",
        name: "list_pipelines",
        description: "List the account's managed indexes (pipelines) with their ids.",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  @impl Flux.Plugin.Tool
  def invoke(credentials, "retrieve", args) do
    pipeline = to_string(args["pipeline_id"] || credentials["pipeline_id"] || "")
    query = to_string(args["query"] || "")

    cond do
      query == "" ->
        {:error, "query is required"}

      pipeline == "" ->
        {:error, "no pipeline id — pass pipeline_id or set a default in the credentials"}

      true ->
        payload = %{
          "query" => query,
          "dense_similarity_top_k" => normalize_top_k(args["top_k"])
        }

        with {:ok, body} <- post(credentials, "/api/v1/pipelines/#{pipeline}/retrieve", payload) do
          nodes =
            for entry <- List.wrap(body["retrieval_nodes"]) do
              %{
                "text" => get_in(entry, ["node", "text"]) || "",
                "score" => entry["score"]
              }
            end

          text =
            nodes
            |> Enum.map(& &1["text"])
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("\n\n---\n\n")

          {:ok, %{text: text, data: %{"nodes" => nodes, "count" => length(nodes)}}}
        end
    end
  end

  def invoke(credentials, "run_workflow", args) do
    deployment = to_string(args["deployment"] || "")
    input = to_string(args["input"] || "")

    if deployment == "" do
      {:error, "deployment is required"}
    else
      path = "/deployments/#{URI.encode(deployment)}/tasks/run"

      with {:ok, body} <- post(credentials, path, %{"input" => input}) do
        {:ok, %{text: result_text(body), data: body}}
      end
    end
  end

  def invoke(credentials, "list_pipelines", _args) do
    with {:ok, body} <- get(credentials, "/api/v1/pipelines") do
      pipelines =
        for entry <- List.wrap(body), is_map(entry) do
          %{"id" => entry["id"], "name" => entry["name"]}
        end

      text = Enum.map_join(pipelines, "\n", &"#{&1["name"]} (#{&1["id"]})")
      {:ok, %{text: text, data: %{"pipelines" => pipelines}}}
    end
  end

  def invoke(_credentials, operation, _args), do: {:error, "unknown operation #{operation}"}

  defp normalize_top_k(top_k) when is_integer(top_k) and top_k in 1..50, do: top_k
  defp normalize_top_k(_top_k), do: 5

  # llama_deploy task results are commonly {"result": ...} but stay
  # honest for other shapes.
  defp result_text(%{"result" => result}) when is_binary(result), do: result
  defp result_text(body), do: Jason.encode!(body)

  defp base_url(credentials) do
    case String.trim(to_string(credentials["base_url"] || "")) do
      "" -> @default_base
      url -> String.trim_trailing(url, "/")
    end
  end

  defp headers(credentials) do
    case to_string(credentials["api_key"] || "") do
      "" -> []
      key -> [{"authorization", "Bearer #{key}"}]
    end
  end

  defp get(credentials, path) do
    request(credentials, path, fn url ->
      Req.get(
        SSE.req_options(
          url: url,
          headers: headers(credentials),
          redirect: false,
          max_retries: 1,
          receive_timeout: 30_000
        )
      )
    end)
  end

  defp post(credentials, path, payload) do
    request(credentials, path, fn url ->
      Req.post(
        SSE.req_options(
          url: url,
          json: payload,
          headers: headers(credentials),
          redirect: false,
          max_retries: 1,
          receive_timeout: 120_000
        )
      )
    end)
  end

  defp request(credentials, path, fun) do
    url = base_url(credentials) <> path

    with :ok <- Flux.SSRF.verify_url(url),
         {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(url),
         :ok <- size_check(body) do
      {:ok, body}
    else
      {:ok, %{status: 401}} -> {:error, "HTTP 401 — check the API key"}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp size_check(body) when is_binary(body) and byte_size(body) > @max_body_bytes,
    do: {:error, "response too large"}

  defp size_check(_body), do: :ok
end
