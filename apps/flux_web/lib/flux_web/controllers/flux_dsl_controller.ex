defmodule FluxWeb.FluxDslController do
  @moduledoc "Downloads a flux as portable DSL."
  use FluxWeb, :controller

  alias Flux.Workflows
  alias Flux.Workflows.Workflow

  plug FluxWeb.Plugs.RequirePermission, :app_import_export_dsl

  def export(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Workflows.get_workflow(scope, id) do
      %Workflow{} = workflow ->
        send_download(
          conn,
          {:binary, Flux.Workflows.DSL.export(workflow)},
          filename: "#{workflow.name}.yml",
          content_type: "application/yaml"
        )

      {:error, :not_found} ->
        conn |> put_flash(:error, "Flux not found.") |> redirect(to: ~p"/console/fluxes")
    end
  end

  def export_app(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Flux.Chat.get_app(scope, id) do
      %Flux.Chat.App{} = app ->
        send_download(
          conn,
          {:binary, Flux.Workflows.DSL.export_app(app)},
          filename: "#{app.name}.yml",
          content_type: "application/yaml"
        )

      {:error, :not_found} ->
        conn |> put_flash(:error, "App not found.") |> redirect(to: ~p"/console/apps")
    end
  end
end
