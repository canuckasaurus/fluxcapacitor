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

  @doc "Bulk export: the selected fluxes as one multi-document YAML file."
  def export_many(conn, %{"ids" => ids}) when is_list(ids) do
    scope = conn.assigns.current_scope

    documents =
      for id <- Enum.take(ids, 100),
          match?({:ok, _uuid}, Ecto.UUID.cast(id)),
          %Workflow{} = workflow <- [Workflows.get_workflow(scope, id)] do
        Flux.Workflows.DSL.export(workflow)
      end

    case documents do
      [] ->
        conn
        |> put_flash(:error, "Nothing to export.")
        |> redirect(to: ~p"/console/fluxes")

      documents ->
        send_download(
          conn,
          {:binary, Enum.join(documents, "\n---\n")},
          filename: "fluxes-export.yml",
          content_type: "application/yaml"
        )
    end
  end

  def export_many(conn, _params) do
    conn |> put_flash(:error, "Nothing to export.") |> redirect(to: ~p"/console/fluxes")
  end

  @doc "Downloads a finished run as a golden replay fixture."
  def run_fixture(conn, %{"run_id" => run_id}) do
    case Workflows.export_run_fixture(conn.assigns.current_scope, run_id) do
      {:ok, fixture} ->
        send_download(
          conn,
          {:binary, Jason.encode!(fixture, pretty: true)},
          filename: "run-fixture.json",
          content_type: "application/json"
        )

      {:error, :not_finished} ->
        conn
        |> put_flash(:error, "Only finished runs export as fixtures.")
        |> redirect(to: ~p"/console/fluxes")

      {:error, _reason} ->
        conn |> put_flash(:error, "Run not found.") |> redirect(to: ~p"/console/fluxes")
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
