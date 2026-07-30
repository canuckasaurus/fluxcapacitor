defmodule FluxWeb.ConsoleLive.Fluxes do
  @moduledoc false
  use FluxWeb, :live_view

  alias Flux.RBAC
  alias Flux.Workflows
  alias Flux.Workflows.Workflow

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "Fluxes",
       creating: false,
       form: to_form(Workflow.changeset(%Workflow{}, %{})),
       can_create: RBAC.can?(scope, :app_create_and_management)
     )
     |> load_workflows()}
  end

  defp load_workflows(socket) do
    scope = socket.assigns.current_scope
    workflows = Workflows.list_workflows(scope)

    versions =
      Map.new(workflows, fn workflow ->
        {workflow.id, Workflows.latest_version(scope, workflow.id)}
      end)

    assign(socket, workflows: workflows, versions: versions)
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false)}
  end

  def handle_event("save", %{"workflow" => params}, socket) do
    case Workflows.create_workflow(socket.assigns.current_scope, params) do
      {:ok, workflow} ->
        {:noreply,
         socket
         |> put_flash(:info, "Flux \"#{workflow.name}\" created.")
         |> push_navigate(to: ~p"/console/fluxes/#{workflow.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to create fluxes.")}
    end
  end

  def handle_event("delete", %{"workflow-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Workflow{} = workflow <- Workflows.get_workflow(scope, id),
         {:ok, _deleted} <- Workflows.delete_workflow(scope, workflow) do
      {:noreply, socket |> put_flash(:info, "Flux deleted.") |> load_workflows()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not delete that flux.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:fluxes}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Fluxes</h1>
          <p class="opacity-70 mt-1">Design, debug, and publish AI workflows.</p>
        </div>
        <button :if={@can_create and not @creating} class="btn btn-primary" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> New Flux
        </button>
      </div>

      <div :if={@creating} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Create a flux</h2>
        <.form for={@form} id="workflow-form" phx-submit="save" class="space-y-3">
          <.input field={@form[:name]} type="text" label="Name" placeholder="Support Triage" />
          <.input
            field={@form[:description]}
            type="textarea"
            label="Description"
            placeholder="What does this flux do?"
          />
          <div class="flex gap-2">
            <button class="btn btn-primary">Create flux</button>
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          </div>
        </.form>
      </div>

      <div
        :if={@workflows == [] and not @creating}
        class="card border border-dashed border-base-300 p-12 text-center space-y-3"
      >
        <.icon name="hero-squares-2x2" class="size-10 text-primary mx-auto" />
        <h2 class="font-semibold text-lg">No fluxes yet</h2>
        <p class="opacity-70 text-sm">
          Create your first flux to build a workflow on the visual canvas.
        </p>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div
          :for={workflow <- @workflows}
          class="card border border-base-200 p-6 space-y-2"
          id={"workflow-#{workflow.id}"}
        >
          <div class="flex items-start justify-between">
            <h2 class="font-semibold">{workflow.name}</h2>
            <button
              :if={@can_create}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete"
              phx-value-workflow-id={workflow.id}
              data-confirm={"Delete #{workflow.name}?"}
            >
              Delete
            </button>
          </div>
          <p class="text-xs opacity-60">
            {length(workflow.graph["nodes"] || [])} nodes
            <span :if={@versions[workflow.id]} class="badge badge-success badge-sm ml-1">
              v{@versions[workflow.id].version} published
            </span>
            <span :if={is_nil(@versions[workflow.id])} class="badge badge-ghost badge-sm ml-1">
              draft
            </span>
          </p>
          <p :if={workflow.description} class="text-sm opacity-70">{workflow.description}</p>
          <.link
            navigate={~p"/console/fluxes/#{workflow.id}"}
            class="btn btn-sm btn-outline w-fit"
          >
            Open canvas
          </.link>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
