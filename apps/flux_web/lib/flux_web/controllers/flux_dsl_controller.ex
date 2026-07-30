defmodule FluxWeb.FluxDslController do
  @moduledoc "Downloads a flux as Dify-importable DSL."
  use FluxWeb, :controller

  alias Flux.Workflows
  alias Flux.Workflows.Workflow

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
end
