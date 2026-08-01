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
       default_model: Providers.default_model(scope),
       retention_days: Accounts.retention_days(scope),
       alert_url: Accounts.alert_url(scope),
       can_scim: RBAC.can?(scope, :workspace_member_manage),
       scim_enabled: Accounts.scim_enabled?(scope),
       scim_token: nil,
       plan: Flux.Features.plan(scope)
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

  def handle_event("set_retention", %{"days" => days}, socket) do
    parsed =
      case Integer.parse(String.trim(days)) do
        {n, ""} when n in 1..3650 -> n
        _blank_or_invalid -> nil
      end

    case Accounts.set_retention_days(socket.assigns.current_scope, parsed) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, (parsed && "Retention set to #{parsed} days.") || "Retention off.")
         |> assign(retention_days: parsed)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to change retention.")}
    end
  end

  def handle_event("set_plan", %{"plan" => plan}, socket) do
    case Flux.Features.set_plan(socket.assigns.current_scope, plan) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan set to #{plan}.")
         |> assign(plan: plan)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only the owner can change the plan.")}

      {:error, :unknown_plan} ->
        {:noreply, put_flash(socket, :error, "Unknown plan.")}
    end
  end

  def handle_event("enable_scim", _params, socket) do
    case Accounts.enable_scim(socket.assigns.current_scope) do
      {:ok, raw} ->
        {:noreply, assign(socket, scim_enabled: true, scim_token: raw)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage SCIM.")}
    end
  end

  def handle_event("disable_scim", _params, socket) do
    case Accounts.disable_scim(socket.assigns.current_scope) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "SCIM disabled — the token no longer works.")
         |> assign(scim_enabled: false, scim_token: nil)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage SCIM.")}
    end
  end

  def handle_event("set_alert_url", %{"url" => url}, socket) do
    case Accounts.set_alert_url(socket.assigns.current_scope, url) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alert webhook saved.")
         |> assign(alert_url: Accounts.alert_url(socket.assigns.current_scope))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to change alerts.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
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

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Data retention</h2>
        <p class="text-sm opacity-70">
          Runs and chat messages older than this are pruned nightly. Blank keeps
          everything forever; conversations and the audit trail are never pruned.
        </p>
        <form phx-submit="set_retention" id="retention-form" class="flex gap-2 items-center">
          <input
            type="number"
            name="days"
            value={@retention_days}
            min="1"
            max="3650"
            placeholder="∞"
            class="input input-bordered input-sm w-28"
          />
          <span class="text-sm opacity-70">days</span>
          <button class="btn btn-primary btn-sm">Save</button>
        </form>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Failure alerts</h2>
        <p class="text-sm opacity-70">
          Failed runs POST a JSON alert to this webhook (blank disables).
        </p>
        <form phx-submit="set_alert_url" id="alert-url-form" class="flex gap-2">
          <input
            type="url"
            name="url"
            value={@alert_url}
            placeholder="https://hooks.example.com/flux-alerts"
            class="input input-bordered input-sm w-full max-w-md"
          />
          <button class="btn btn-primary btn-sm">Save</button>
        </form>
      </div>

      <div :if={@owner?} class="card border border-base-200 p-6 space-y-3" id="plan-card">
        <h2 class="font-semibold">Plan</h2>
        <p class="text-sm opacity-70">
          Self-hosted deployments run as <span class="font-mono text-xs">enterprise</span>
          (everything on). Lower plans gate custom roles, annotations, datasource
          sync, SCIM, and LLM entity extraction — the hook a licensing backend
          plugs into.
        </p>
        <form phx-change="set_plan" id="plan-form">
          <select name="plan" class="select select-bordered select-sm w-48">
            <option
              :for={plan <- Enum.sort(Flux.Features.plans())}
              value={plan}
              selected={@plan == plan}
            >
              {plan}
            </option>
          </select>
        </form>
      </div>

      <div :if={@can_scim} class="card border border-base-200 p-6 space-y-3" id="scim-card">
        <h2 class="font-semibold">SCIM provisioning</h2>
        <p class="text-sm opacity-70">
          Let your identity provider create and remove members automatically.
          Base URL: <span class="font-mono text-xs">{url(~p"/scim/v2")}</span>
          — provisioned users join as <span class="font-mono text-xs">normal</span>
          members.
        </p>
        <div :if={@scim_token} class="space-y-1">
          <p class="text-sm text-warning">Copy this bearer token now — it is shown once:</p>
          <pre class="rounded bg-base-200 p-2 text-xs overflow-x-auto" id="scim-token">{@scim_token}</pre>
        </div>
        <div class="flex gap-2">
          <button class="btn btn-primary btn-sm" phx-click="enable_scim">
            {(@scim_enabled && "Rotate token") || "Enable SCIM"}
          </button>
          <button
            :if={@scim_enabled}
            class="btn btn-ghost btn-sm text-error"
            phx-click="disable_scim"
            data-confirm="Disable SCIM? The current token stops working."
          >
            Disable
          </button>
        </div>
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
