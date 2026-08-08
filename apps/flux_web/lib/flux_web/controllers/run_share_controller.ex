defmodule FluxWeb.RunShareController do
  @moduledoc """
  Read-only shared run traces: a signed token (30-day expiry) in the URL
  is the authorization, so a failing run can be handed to someone without
  console access. No mutations, no navigation into the console.
  """
  use FluxWeb, :controller

  @salt "run-share"
  @max_age 60 * 60 * 24 * 30

  def show(conn, %{"token" => token}) do
    with {:ok, run_id} <- Phoenix.Token.verify(FluxWeb.Endpoint, @salt, token, max_age: @max_age),
         %Flux.Workflows.WorkflowRun{} = run <-
           Flux.Repo.get(Flux.Workflows.WorkflowRun, run_id, skip_workspace_guard: true) do
      workflow =
        run.workflow_id &&
          Flux.Repo.get(Flux.Workflows.Workflow, run.workflow_id, skip_workspace_guard: true)

      render(conn, :show, run: run, workflow_name: (workflow && workflow.name) || "Flux")
    else
      _invalid_or_gone ->
        conn
        |> put_status(404)
        |> put_view(html: FluxWeb.ErrorHTML)
        |> render("404.html")
    end
  end

  @doc "Signs a share token for a run id (used by the runs page)."
  def sign(run_id), do: Phoenix.Token.sign(FluxWeb.Endpoint, @salt, run_id)
end
