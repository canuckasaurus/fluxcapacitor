defmodule Flux.Export do
  @moduledoc """
  Whole-workspace export: every flux and app as portable DSL, every
  dataset's settings and document text, and the workspace's non-secret
  settings — one JSON document for disaster recovery or migration.
  Secrets never leave: provider credentials, API token hashes, and the
  SCIM token hash are excluded by construction.
  """

  alias Flux.Accounts.Scope
  alias Flux.Repo

  @secret_settings ~w(scim_token_hash)

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
        "datasets" => datasets(scope)
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
      %{"name" => workflow.name, "dsl" => Flux.Workflows.DSL.export(workflow)}
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
            "score_threshold" => dataset.score_threshold
          },
          "documents" =>
            for document <- rag.list_documents(scope, dataset.id) do
              %{"name" => document.name, "content" => document.content}
            end
        }
      end
    else
      []
    end
  end
end
