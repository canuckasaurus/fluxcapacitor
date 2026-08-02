defmodule Flux.Plugins.LabelStudio do
  @moduledoc """
  Built-in Label Studio connector — the labeling half of a custom-model
  loop. As a **tool** it pushes tasks into a project, lists projects, and
  exports finished annotations (feed the export to a code node to train
  with the sandbox's ML toolkit). As a **datasource** it syncs labeled
  tasks into a knowledge dataset.

  Works against the Apache-2.0 community edition
  (`docker compose --profile labeling up -d labelstudio` in this repo).
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.Datasource
  @behaviour Flux.Plugin.Tool

  alias Flux.Plugin.{CredentialField, Manifest}
  alias Flux.Plugin.Datasource.SourceDoc
  alias Flux.Plugin.Tool.Operation
  alias Flux.Plugins.SSE

  @max_body_bytes 10_000_000
  @max_tasks_per_call 100

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "label_studio",
      name: "Label Studio",
      version: "0.1.0",
      category: :tool,
      capabilities: [:tool, :datasource],
      description:
        "Push tasks to Label Studio for human labeling, pull finished " <>
          "annotations back — as flux functions or a dataset sync.",
      credential_schema: [
        %CredentialField{
          key: "base_url",
          label: "Base URL",
          type: :url,
          placeholder: "http://labelstudio:8080"
        },
        %CredentialField{
          key: "api_token",
          label: "API token",
          type: :secret,
          placeholder: "Label Studio → Account & Settings → Access Token"
        },
        %CredentialField{
          key: "project_id",
          label: "Default project id — optional",
          type: :text,
          required: false,
          placeholder: "leave blank to pass per call"
        }
      ]
    }
  end

  @doc "Credential validation = the projects listing answers."
  def validate_credentials(credentials) do
    case get(credentials, "/api/projects") do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Tool

  @impl Flux.Plugin.Tool
  def operations(_credentials) do
    [
      %Operation{
        id: "list_projects",
        name: "list_projects",
        description: "List Label Studio projects with ids and task counts.",
        parameters: %{"type" => "object", "properties" => %{}}
      },
      %Operation{
        id: "create_tasks",
        name: "create_tasks",
        description:
          "Queue items for human labeling: each item becomes one Label " <>
            "Studio task. Strings become {\"text\": item}; objects import as-is.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "items" => %{
              "type" => "array",
              "description" => "The items to label (strings or data objects).",
              "items" => %{}
            },
            "project_id" => %{
              "type" => "string",
              "description" => "Project id; the credential default when omitted."
            }
          },
          "required" => ["items"]
        }
      },
      %Operation{
        id: "export_annotations",
        name: "export_annotations",
        description:
          "Export a project's finished annotations (labeled tasks) as " <>
            "JSON — training data for a code node.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "project_id" => %{
              "type" => "string",
              "description" => "Project id; the credential default when omitted."
            }
          }
        }
      }
    ]
  end

  @impl Flux.Plugin.Tool
  def invoke(credentials, "list_projects", _args) do
    with {:ok, projects} <- list_projects(credentials) do
      text =
        Enum.map_join(projects, "\n", fn project ->
          "#{project["id"]}: #{project["title"]} (#{project["task_number"] || 0} tasks)"
        end)

      {:ok, %{text: text, data: %{"projects" => projects, "count" => length(projects)}}}
    end
  end

  def invoke(credentials, "create_tasks", args) do
    items = List.wrap(args["items"])

    with {:ok, project} <- resolve_project(credentials, args),
         :ok <- validate_items(items) do
      tasks =
        for item <- items do
          case item do
            %{} = data -> %{"data" => data}
            other -> %{"data" => %{"text" => to_string(other)}}
          end
        end

      with {:ok, body} <- post(credentials, "/api/projects/#{project}/import", tasks) do
        count = body["task_count"] || length(tasks)
        {:ok, %{text: "queued #{count} tasks for labeling", data: %{"task_count" => count}}}
      end
    end
  end

  def invoke(credentials, "export_annotations", args) do
    with {:ok, project} <- resolve_project(credentials, args),
         {:ok, tasks} <- export_labeled(credentials, project) do
      {:ok,
       %{
         text: "#{length(tasks)} labeled tasks",
         data: %{"tasks" => tasks, "count" => length(tasks)}
       }}
    end
  end

  def invoke(_credentials, operation, _args), do: {:error, "unknown operation #{operation}"}

  ## Datasource — labeled tasks sync into a knowledge dataset

  @impl Flux.Plugin.Datasource
  def list_documents(credentials) do
    with {:ok, project} <- resolve_project(credentials, %{}),
         {:ok, tasks} <- export_labeled(credentials, project) do
      case tasks do
        [] ->
          {:error, "no labeled tasks yet — label some in Label Studio first"}

        tasks ->
          {:ok, Enum.map(tasks, &%SourceDoc{id: to_string(&1["id"]), name: task_name(&1)})}
      end
    end
  end

  @impl Flux.Plugin.Datasource
  def fetch_document(credentials, task_id) do
    with {:ok, project} <- resolve_project(credentials, %{}),
         {:ok, tasks} <- export_labeled(credentials, project),
         %{} = task <-
           Enum.find(tasks, &(to_string(&1["id"]) == task_id)) ||
             {:error, "task #{task_id} is not in the labeled export"} do
      content =
        Jason.encode!(
          %{
            "data" => task["data"],
            "annotations" =>
              for annotation <- List.wrap(task["annotations"]) do
                %{"result" => annotation["result"]}
              end
          },
          pretty: true
        )

      {:ok, %{name: task_name(task), content: content}}
    end
  end

  ## Internals

  defp list_projects(credentials) do
    with {:ok, body} <- get(credentials, "/api/projects") do
      {:ok, List.wrap(body["results"] || body)}
    end
  end

  defp export_labeled(credentials, project) do
    path = "/api/projects/#{project}/export?exportType=JSON&download_all_tasks=false"

    with {:ok, body} <- get(credentials, path) do
      {:ok, List.wrap(body)}
    end
  end

  defp resolve_project(credentials, args) do
    case String.trim(to_string(args["project_id"] || credentials["project_id"] || "")) do
      "" -> {:error, "no project id — pass project_id or set a default in the credentials"}
      project -> {:ok, URI.encode_www_form(project)}
    end
  end

  defp validate_items([]), do: {:error, "items is empty — nothing to label"}

  defp validate_items(items) when length(items) > @max_tasks_per_call,
    do: {:error, "at most #{@max_tasks_per_call} items per call"}

  defp validate_items(_items), do: :ok

  defp task_name(task) do
    case task["data"] do
      %{"text" => text} when is_binary(text) and text != "" ->
        "task #{task["id"]}: #{String.slice(text, 0, 60)}"

      _other ->
        "task #{task["id"]}"
    end
  end

  defp headers(credentials) do
    case String.trim(to_string(credentials["api_token"] || "")) do
      "" -> []
      token -> [{"authorization", "Token #{token}"}]
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
          receive_timeout: 60_000
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
          receive_timeout: 60_000
        )
      )
    end)
  end

  defp request(credentials, path, fun) do
    base = String.trim_trailing(String.trim(to_string(credentials["base_url"] || "")), "/")

    cond do
      base == "" ->
        {:error, "base_url is required"}

      true ->
        url = base <> path

        with :ok <- Flux.SSRF.verify_url(url),
             {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(url),
             :ok <- size_check(body) do
          {:ok, body}
        else
          {:ok, %{status: 401}} -> {:error, "HTTP 401 — check the API token"}
          {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
          {:error, message} when is_binary(message) -> {:error, message}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  defp size_check(body) when is_binary(body) and byte_size(body) > @max_body_bytes,
    do: {:error, "response too large"}

  defp size_check(_body), do: :ok
end
