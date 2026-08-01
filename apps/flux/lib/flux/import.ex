defmodule Flux.Import do
  @moduledoc """
  Restores a `Flux.Export` archive into the current workspace: fluxes
  re-import through the DSL pipeline, apps through the app-DSL parser,
  and datasets are recreated with their settings and documents (indexing
  re-runs through Oban). Entries that fail to parse are skipped and
  reported as warnings rather than aborting the rest.

  Model bindings and dataset/workflow references travel by value inside
  the DSL, so cross-entity ids (a chatflow's workflow, a knowledge
  node's dataset) may need rebinding after import — same caveat as
  single-flux DSL import.
  """

  alias Flux.Accounts.Scope

  def workspace(%Scope{} = scope, json) when is_binary(json) do
    with :ok <- Flux.RBAC.authorize(scope, :app_import_export_dsl),
         {:ok, %{"format" => "fluxcapacitor-workspace-export", "version" => 1} = payload} <-
           decode(json) do
      {flux_count, flux_warnings} = import_fluxes(scope, List.wrap(payload["fluxes"]))
      {app_count, app_warnings} = import_apps(scope, List.wrap(payload["apps"]))

      {dataset_count, document_count, dataset_warnings} =
        import_datasets(scope, List.wrap(payload["datasets"]))

      counts = %{
        fluxes: flux_count,
        apps: app_count,
        datasets: dataset_count,
        documents: document_count,
        warnings: flux_warnings ++ app_warnings ++ dataset_warnings
      }

      Flux.Audit.record(scope, "workspace.import",
        resource_type: "workspace",
        resource_id: Scope.workspace_id(scope),
        metadata: %{
          "fluxes" => flux_count,
          "apps" => app_count,
          "datasets" => dataset_count,
          "warnings" => length(counts.warnings)
        }
      )

      {:ok, counts}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _invalid -> {:error, "not a FluxCapacitor workspace export"}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = payload} -> {:ok, payload}
      _invalid -> :error
    end
  end

  defp import_fluxes(scope, entries) do
    Enum.reduce(entries, {0, []}, fn entry, {count, warnings} ->
      case Flux.Workflows.import_dsl(scope, entry["dsl"] || "") do
        {:ok, _workflow, dsl_warnings} ->
          {count + 1, warnings ++ Enum.map(dsl_warnings, &"flux #{entry["name"]}: #{&1}")}

        {:error, reason} ->
          {count, warnings ++ ["flux #{entry["name"]}: #{format(reason)}"]}
      end
    end)
  end

  defp import_apps(scope, entries) do
    Enum.reduce(entries, {0, []}, fn entry, {count, warnings} ->
      with {:ok, %{attrs: attrs}} <- Flux.Workflows.DSL.parse_app(entry["dsl"] || ""),
           {:ok, _app} <- Flux.Chat.create_app(scope, attrs) do
        {count + 1, warnings}
      else
        {:error, reason} ->
          {count, warnings ++ ["app #{entry["name"]}: #{format(reason)}"]}
      end
    end)
  end

  defp import_datasets(scope, entries) do
    rag = Application.get_env(:flux, :rag_module, Flux.RAG)

    Enum.reduce(entries, {0, 0, []}, fn entry, {datasets, documents, warnings} ->
      settings = entry["settings"] || %{}

      attrs =
        settings
        |> Map.take(~w(embedding_plugin_id embedding_model chunk_size chunk_overlap
             rerank_plugin_id rerank_model retrieval_top_k score_threshold))
        |> Map.merge(%{"name" => entry["name"], "description" => entry["description"]})

      case rag.create_dataset(scope, attrs) do
        {:ok, dataset} ->
          added =
            Enum.count(List.wrap(entry["documents"]), fn document ->
              match?(
                {:ok, _doc},
                rag.add_document(scope, dataset, %{
                  name: to_string(document["name"] || "imported"),
                  content: to_string(document["content"] || "")
                })
              )
            end)

          {datasets + 1, documents + added, warnings}

        {:error, reason} ->
          {datasets, documents, warnings ++ ["dataset #{entry["name"]}: #{format(reason)}"]}
      end
    end)
  end

  defp format(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
