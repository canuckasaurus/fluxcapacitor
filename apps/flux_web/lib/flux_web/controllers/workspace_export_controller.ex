defmodule FluxWeb.WorkspaceExportController do
  @moduledoc "Downloads the whole workspace as one JSON archive (see Flux.Export)."
  use FluxWeb, :controller

  plug FluxWeb.Plugs.RequirePermission, :app_import_export_dsl

  @doc "Full JSONL of recent runs — inputs, outputs, per-node traces."
  def runs(conn, _params) do
    scope = conn.assigns.current_scope

    jsonl =
      scope
      |> Flux.Workflows.list_workspace_runs(%{}, 500)
      |> Enum.map_join("\n", fn %{run: run, workflow_name: workflow_name} ->
        Jason.encode!(%{
          id: run.id,
          workflow: workflow_name,
          workflow_id: run.workflow_id,
          status: run.status,
          source: run.source,
          version: run.version,
          inserted_at: run.inserted_at,
          elapsed_ms: run.elapsed_ms,
          inputs: run.inputs,
          outputs: run.outputs,
          error: run.error,
          usage: run.usage,
          node_executions: run.node_executions
        })
      end)

    send_download(conn, {:binary, jsonl},
      filename: "runs.jsonl",
      content_type: "application/x-ndjson"
    )
  end

  def usage(conn, _params) do
    send_download(
      conn,
      {:binary, Flux.Usage.flux_costs_csv(conn.assigns.current_scope)},
      filename: "flux-costs.csv",
      content_type: "text/csv"
    )
  end

  def export(conn, _params) do
    case Flux.Export.workspace(conn.assigns.current_scope) do
      {:ok, payload} ->
        send_download(
          conn,
          {:binary, Jason.encode!(payload, pretty: true)},
          filename: "workspace-export.json",
          content_type: "application/json"
        )

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "You don't have permission to export.")
        |> redirect(to: ~p"/console/settings")
    end
  end

  def import(conn, %{"archive" => %Plug.Upload{path: path}}) do
    case Flux.Import.workspace(conn.assigns.current_scope, File.read!(path)) do
      {:ok, counts} ->
        summary =
          "Imported #{counts.fluxes} flux(es), #{counts.apps} app(s), " <>
            "#{counts.datasets} dataset(s) with #{counts.documents} document(s), " <>
            "#{counts.eval_sets} eval set(s), #{counts.retrieval_cases} retrieval case(s), " <>
            "#{counts.labeling_projects} labeling project(s)."

        summary =
          case counts.warnings do
            [] ->
              summary

            warnings ->
              summary <> " #{length(warnings)} warning(s): #{Enum.join(warnings, " · ")}"
          end

        conn |> put_flash(:info, summary) |> redirect(to: ~p"/console/settings")

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "You don't have permission to import.")
        |> redirect(to: ~p"/console/settings")

      {:error, message} ->
        conn |> put_flash(:error, message) |> redirect(to: ~p"/console/settings")
    end
  end

  def import(conn, _params) do
    conn
    |> put_flash(:error, "Choose an export archive (.json) to import.")
    |> redirect(to: ~p"/console/settings")
  end
end
