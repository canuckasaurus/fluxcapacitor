defmodule FluxWeb.WorkspaceExportController do
  @moduledoc "Downloads the whole workspace as one JSON archive (see Flux.Export)."
  use FluxWeb, :controller

  plug FluxWeb.Plugs.RequirePermission, :app_import_export_dsl

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
end
