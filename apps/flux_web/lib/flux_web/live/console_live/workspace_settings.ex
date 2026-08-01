defmodule FluxWeb.ConsoleLive.WorkspaceSettings do
  @moduledoc "Workspace settings: rename, default model, danger zone."
  use FluxWeb, :live_view

  alias Flux.Accounts
  alias Flux.Providers
  alias Flux.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: "Workspace settings",
       can_rename: RBAC.can?(scope, :customization_manage),
       can_model: RBAC.can?(scope, :plugin_model_config),
       owner?: Flux.Accounts.Scope.role(scope) == :owner,
       models: Providers.available_models(scope),
       default_model: Providers.default_model(scope)
     )}
  end

  @impl true
  def handle_event("rename", %{"name" => name}, socket) do
    case Accounts.rename_workspace(socket.assigns.current_scope, name) do
      {:ok, workspace} ->
        scope = %{socket.assigns.current_scope | workspace: workspace}

        {:noreply,
         socket
         |> put_flash(:info, "Workspace renamed.")
         |> assign(current_scope: scope)}

      {:error, :invalid_name} ->
        {:noreply, put_flash(socket, :error, "Enter a workspace name.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to rename.")}
    end
  end

  def handle_event("set_default_model", %{"model_choice" => choice}, socket) do
    {plugin_id, model} =
      case String.split(choice, "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _cleared -> {"", ""}
      end

    case Providers.set_default_model(socket.assigns.current_scope, plugin_id, model) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Default model saved.")
         |> assign(default_model: Providers.default_model(socket.assigns.current_scope))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to set the default.")}
    end
  end

  def handle_event("delete_workspace", %{"confirm" => confirm}, socket) do
    workspace = socket.assigns.current_scope.workspace

    cond do
      confirm != workspace.name ->
        {:noreply, put_flash(socket, :error, "Type the workspace name exactly to confirm.")}

      true ->
        case Accounts.delete_workspace(socket.assigns.current_scope) do
          {:ok, _workspace} ->
            {:noreply,
             socket
             |> put_flash(:info, "Workspace deleted.")
             |> redirect(to: ~p"/console")}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "Only the owner can delete the workspace.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:settings}
    >
      <div>
        <h1 class="text-2xl font-bold">Workspace settings</h1>
        <p class="opacity-70 mt-1">{@current_scope.workspace.name}</p>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Name</h2>
        <form phx-submit="rename" id="rename-form" class="flex gap-2">
          <input
            type="text"
            name="name"
            value={@current_scope.workspace.name}
            required
            class="input input-bordered w-full max-w-md"
          />
          <button class="btn btn-primary">Rename</button>
        </form>
      </div>

      <div :if={@can_model} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Default model</h2>
        <p class="text-sm opacity-70">
          LLM and agent nodes that name no model fall back to this.
        </p>
        <form phx-change="set_default_model" id="settings-default-model-form">
          <select name="model_choice" class="select select-bordered select-sm w-full max-w-md">
            <option value="" selected={@default_model == nil}>No default</option>
            <option
              :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
              value={"#{pid}|#{m.name}"}
              selected={
                @default_model != nil and
                  @default_model["provider_plugin_id"] == pid and
                  @default_model["model"] == m.name
              }
            >
              {pname} — {m.label}
            </option>
          </select>
        </form>
      </div>

      <div :if={@owner?} class="card border border-error/40 p-6 space-y-3">
        <h2 class="font-semibold text-error">Danger zone</h2>
        <p class="text-sm opacity-70">
          Deleting the workspace permanently removes every app, flux, dataset,
          run, and member. Type
          <span class="font-mono font-semibold">{@current_scope.workspace.name}</span>
          to confirm.
        </p>
        <form phx-submit="delete_workspace" id="delete-workspace-form" class="flex gap-2">
          <input
            type="text"
            name="confirm"
            placeholder={@current_scope.workspace.name}
            class="input input-bordered input-sm w-full max-w-md"
          />
          <button class="btn btn-error btn-sm" data-confirm="This cannot be undone. Delete?">
            Delete workspace
          </button>
        </form>
      </div>
    </Layouts.console>
    """
  end
end
