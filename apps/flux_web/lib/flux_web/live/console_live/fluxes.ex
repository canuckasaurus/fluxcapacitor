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
       importing: false,
       form: to_form(Workflow.changeset(%Workflow{}, %{})),
       can_create: RBAC.can?(scope, :app_create_and_management),
       can_export: RBAC.can?(scope, :app_import_export_dsl),
       selected: MapSet.new()
     )
     |> load_workflows()}
  end

  defp load_workflows(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      workflows: Workflows.list_workflows(scope),
      versions: Workflows.latest_versions(scope),
      trashed: Workflows.list_trashed_workflows(scope)
    )
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true, importing: false)}
  end

  def handle_event("import_form", _params, socket) do
    {:noreply, assign(socket, importing: true, creating: false)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false, importing: false)}
  end

  def handle_event("import", %{"dsl" => dsl}, socket) do
    case Workflows.import_dsl(socket.assigns.current_scope, dsl) do
      {:ok, workflow, warnings} ->
        flash =
          case warnings do
            [] -> "Imported \"#{workflow.name}\"."
            warnings -> "Imported \"#{workflow.name}\" with #{length(warnings)} warning(s)."
          end

        {:noreply,
         socket
         |> put_flash(:info, flash)
         |> push_navigate(to: ~p"/console/fluxes/#{workflow.id}")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to create fluxes.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not save the imported flux.")}
    end
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

  def handle_event("restore", %{"workflow-id" => id}, socket) do
    case Workflows.restore_workflow(socket.assigns.current_scope, id) do
      {:ok, workflow} ->
        {:noreply,
         socket |> put_flash(:info, "\"#{workflow.name}\" restored.") |> load_workflows()}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not restore that flux.")}
    end
  end

  def handle_event("purge", %{"workflow-id" => id}, socket) do
    case Workflows.purge_workflow(socket.assigns.current_scope, id) do
      {:ok, _deleted} ->
        {:noreply, socket |> put_flash(:info, "Deleted forever.") |> load_workflows()}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not delete that flux.")}
    end
  end

  ## Bulk selection

  def handle_event("toggle_select", %{"workflow-id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("select_all", _params, socket) do
    {:noreply, assign(socket, selected: MapSet.new(socket.assigns.workflows, & &1.id))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected: MapSet.new())}
  end

  def handle_event("bulk_delete", _params, socket) do
    scope = socket.assigns.current_scope

    {deleted, failed} =
      Enum.reduce(socket.assigns.selected, {0, 0}, fn id, {deleted, failed} ->
        with %Workflow{} = workflow <- Workflows.get_workflow(scope, id),
             {:ok, _deleted} <- Workflows.delete_workflow(scope, workflow) do
          {deleted + 1, failed}
        else
          _error -> {deleted, failed + 1}
        end
      end)

    flash =
      case failed do
        0 -> "Deleted #{deleted} flux(es)."
        failed -> "Deleted #{deleted} flux(es); #{failed} could not be deleted."
      end

    {:noreply,
     socket
     |> put_flash((failed == 0 && :info) || :error, flash)
     |> assign(selected: MapSet.new())
     |> load_workflows()}
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
        <div class="flex gap-2">
          <button
            :if={@can_create and not @importing}
            class="btn btn-outline"
            phx-click="import_form"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Import DSL
          </button>
          <button :if={@can_create and not @creating} class="btn btn-primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New Flux
          </button>
        </div>
      </div>

      <div :if={@importing} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Import a portable DSL export</h2>
        <p class="text-sm opacity-70">
          Paste a workflow/advanced-chat DSL YAML export. Unsupported nodes are
          dropped with warnings; model bindings may need rebinding after import.
        </p>
        <form phx-submit="import" class="space-y-3">
          <textarea
            name="dsl"
            rows="12"
            class="textarea w-full font-mono text-xs"
            placeholder="app:&#10;  mode: workflow&#10;kind: app&#10;workflow:&#10;  graph: ..."
          ></textarea>
          <div class="flex gap-2">
            <button class="btn btn-primary">Import</button>
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          </div>
        </form>
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

      <div
        :if={@workflows != [] and (@can_create or @can_export)}
        class="flex items-center gap-2"
        id="bulk-toolbar"
      >
        <button class="btn btn-ghost btn-xs" phx-click="select_all">Select all</button>
        <button
          :if={@selected != MapSet.new()}
          class="btn btn-ghost btn-xs"
          phx-click="clear_selection"
        >
          Clear
        </button>
        <span :if={@selected != MapSet.new()} class="text-xs opacity-60">
          {MapSet.size(@selected)} selected
        </span>
        <a
          :if={@can_export and @selected != MapSet.new()}
          href={~p"/console/fluxes-export?#{[ids: Enum.to_list(@selected)]}"}
          class="btn btn-outline btn-xs"
        >
          <.icon name="hero-arrow-up-tray" class="size-3" /> Export selected
        </a>
        <button
          :if={@can_create and @selected != MapSet.new()}
          class="btn btn-outline btn-xs text-error"
          phx-click="bulk_delete"
          data-confirm={"Delete #{MapSet.size(@selected)} flux(es)? This cannot be undone."}
        >
          Delete selected
        </button>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div
          :for={workflow <- @workflows}
          class="card border border-base-200 p-6 space-y-2"
          id={"workflow-#{workflow.id}"}
        >
          <div class="flex items-start justify-between">
            <div class="flex items-center gap-2">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                checked={MapSet.member?(@selected, workflow.id)}
                phx-click="toggle_select"
                phx-value-workflow-id={workflow.id}
                id={"select-#{workflow.id}"}
              />
              <h2 class="font-semibold">{workflow.name}</h2>
            </div>
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

      <details :if={@trashed != []} class="card border border-base-200 p-4" id="flux-trash">
        <summary class="cursor-pointer text-sm font-semibold">
          Trash ({length(@trashed)}) — purged after 30 days
        </summary>
        <div class="mt-2 space-y-2">
          <div
            :for={workflow <- @trashed}
            class="flex items-center gap-2 text-sm"
            id={"trashed-#{workflow.id}"}
          >
            <span>{workflow.name}</span>
            <span class="text-xs opacity-50">
              deleted {Calendar.strftime(workflow.deleted_at, "%Y-%m-%d %H:%M")}
            </span>
            <div :if={@can_create} class="ml-auto flex gap-1">
              <button
                class="btn btn-ghost btn-xs"
                phx-click="restore"
                phx-value-workflow-id={workflow.id}
              >
                Restore
              </button>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="purge"
                phx-value-workflow-id={workflow.id}
                data-confirm={"Delete #{workflow.name} forever? This cannot be undone."}
              >
                Delete forever
              </button>
            </div>
          </div>
        </div>
      </details>
    </Layouts.console>
    """
  end
end
