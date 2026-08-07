defmodule Flux.Export do
  @moduledoc """
  Whole-workspace export: every flux and app as portable DSL, every
  dataset's settings and document text, and the workspace's non-secret
  settings — one JSON document for disaster recovery or migration.
  Secrets never leave: provider credentials, API token hashes, and the
  SCIM token hash are excluded by construction.
  """

  require Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Repo

  @secret_settings ~w(scim_token_hash)

  @doc """
  Minute-tick sweep: workspaces with an `export_schedule` cron in their
  custom_config get their export archive written to storage when it
  fires (once per minute at most, `last_export_at` marker). The archive
  lands on the Files page with a download token, and an `export_ready`
  notification points at it.
  """
  def run_scheduled(now \\ DateTime.utc_now(:second)) do
    minute_start = %{now | second: 0}

    workspaces =
      Flux.Accounts.Workspace
      |> Repo.all()
      |> Enum.filter(&is_binary(get_in(&1.custom_config, ["export_schedule"])))

    for workspace <- workspaces,
        cron_due?(workspace.custom_config["export_schedule"], now),
        not exported_since?(workspace, minute_start) do
      scope = %Scope{
        workspace: workspace,
        membership: %Flux.Accounts.Membership{workspace_id: workspace.id, role: :owner}
      }

      with {:ok, payload} <- workspace(scope) do
        name = "workspace-export-#{Date.to_iso8601(DateTime.to_date(now))}.json"

        {:ok, stored} =
          Flux.Workflows.store_workspace_file(workspace.id, name, Jason.encode!(payload))

        workspace
        |> Ecto.Changeset.change(
          custom_config:
            Map.put(workspace.custom_config, "last_export_at", DateTime.to_iso8601(now))
        )
        |> Repo.update!()

        Flux.Notifications.notify(
          workspace.id,
          "export_ready",
          "Scheduled workspace export ready: #{name}",
          "/console/files"
        )

        stored
      else
        _error -> nil
      end
    end
    |> Enum.filter(& &1)
  end

  defp cron_due?(cron, now) do
    case Oban.Cron.Expression.parse(cron) do
      {:ok, expression} -> Oban.Cron.Expression.now?(expression, now)
      {:error, _reason} -> false
    end
  end

  defp exported_since?(workspace, minute_start) do
    case DateTime.from_iso8601(workspace.custom_config["last_export_at"] || "") do
      {:ok, last, _offset} -> DateTime.compare(last, minute_start) != :lt
      _never -> false
    end
  end

  def workspace(%Scope{} = scope) do
    with :ok <- Flux.RBAC.authorize(scope, :app_import_export_dsl) do
      workspace = Repo.get!(Flux.Accounts.Workspace, Scope.workspace_id(scope))

      payload = %{
        "format" => "fluxcapacitor-workspace-export",
        "version" => 1,
        "workspace" => %{
          "name" => workspace.name,
          "settings" => Map.drop(workspace.custom_config || %{}, @secret_settings)
        },
        "fluxes" => fluxes(scope),
        "apps" => apps(scope),
        "datasets" => datasets(scope),
        "labeling_projects" => labeling_projects(scope)
      }

      Flux.Audit.record(scope, "workspace.export",
        resource_type: "workspace",
        resource_id: workspace.id
      )

      {:ok, payload}
    end
  end

  defp fluxes(scope) do
    for workflow <- Flux.Workflows.list_workflows(scope) do
      %{
        "name" => workflow.name,
        "dsl" => Flux.Workflows.DSL.export(workflow),
        "eval_sets" => eval_sets(scope, workflow.id)
      }
    end
  end

  defp eval_sets(scope, workflow_id) do
    for set <- Flux.Evals.list_sets(scope, workflow_id) do
      %{
        "name" => set.name,
        "gate" => set.gate,
        "schedule" => set.schedule,
        "cases" =>
          for eval_case <- Flux.Evals.list_cases(scope, set.id) do
            %{
              "inputs" => eval_case.inputs,
              "expected" => eval_case.expected,
              "weight" => eval_case.weight
            }
          end
      }
    end
  end

  defp labeling_projects(scope) do
    for project <- Flux.Labeling.list_projects(scope) do
      tasks =
        Flux.Labeling.Task
        |> Repo.scoped(scope)
        |> Ecto.Query.where([t], t.project_id == ^project.id)
        |> Ecto.Query.order_by([t], asc: t.inserted_at)
        |> Repo.all()

      %{
        "name" => project.name,
        "label_type" => to_string(project.label_type),
        "options" => project.options,
        "instructions" => project.instructions,
        "required_labels" => project.required_labels,
        "tasks" =>
          for task <- tasks do
            %{
              "data" => task.data,
              "status" => to_string(task.status),
              "label" => task.label,
              "gold_label" => task.gold_label,
              "source" => task.source
            }
          end
      }
    end
  end

  defp apps(scope) do
    for app <- Flux.Chat.list_apps(scope) do
      %{"name" => app.name, "dsl" => Flux.Workflows.DSL.export_app(app)}
    end
  end

  defp datasets(scope) do
    rag = Application.get_env(:flux, :rag_module, Flux.RAG)

    if Code.ensure_loaded?(rag) do
      for dataset <- rag.list_datasets(scope) do
        %{
          "name" => dataset.name,
          "description" => dataset.description,
          "settings" => %{
            "embedding_plugin_id" => dataset.embedding_plugin_id,
            "embedding_model" => dataset.embedding_model,
            "chunk_size" => dataset.chunk_size,
            "chunk_overlap" => dataset.chunk_overlap,
            "rerank_plugin_id" => dataset.rerank_plugin_id,
            "rerank_model" => dataset.rerank_model,
            "retrieval_top_k" => dataset.retrieval_top_k,
            "score_threshold" => dataset.score_threshold,
            "split_markdown" => dataset.split_markdown,
            "parent_child" => dataset.parent_child,
            "query_expansion" => dataset.query_expansion
          },
          "documents" =>
            for document <- rag.list_documents(scope, dataset.id) do
              %{"name" => document.name, "content" => document.content}
            end,
          "retrieval_cases" =>
            for retrieval_case <- rag.list_retrieval_cases(scope, dataset.id) do
              %{
                "question" => retrieval_case.question,
                "expected" => retrieval_case.expected
              }
            end
        }
      end
    else
      []
    end
  end
end
