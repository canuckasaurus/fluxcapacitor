defmodule FluxWeb.ConsoleLive.Notifications do
  @moduledoc """
  The workspace notification feed: run failures, gate/eval regressions,
  and labeling completions — filterable by kind, readable one at a time
  or all at once.
  """
  use FluxWeb, :live_view

  alias Flux.Notifications

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Notifications.subscribe(scope.workspace.id)
    end

    {:ok,
     assign(socket,
       page_title: "Notifications",
       kind: nil,
       notifications: Notifications.list(scope)
     )}
  end

  @impl true
  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    kind = if kind == socket.assigns.kind, do: nil, else: kind

    {:noreply,
     assign(socket,
       kind: kind,
       notifications: Notifications.list(socket.assigns.current_scope, 30, kind)
     )}
  end

  def handle_event("mark_read", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    Notifications.mark_read(scope, id)
    {:noreply, assign(socket, notifications: Notifications.list(scope, 30, socket.assigns.kind))}
  end

  def handle_event("mark_all_read", _params, socket) do
    scope = socket.assigns.current_scope
    Notifications.mark_all_read(scope)
    {:noreply, assign(socket, notifications: Notifications.list(scope, 30, socket.assigns.kind))}
  end

  @impl true
  def handle_info(:notifications_changed, socket) do
    {:noreply,
     assign(socket,
       notifications: Notifications.list(socket.assigns.current_scope, 30, socket.assigns.kind)
     )}
  end

  defp kind_icon("run_failed"), do: "hero-exclamation-triangle"
  defp kind_icon("eval_regressed"), do: "hero-arrow-trending-down"
  defp kind_icon("gate_blocked"), do: "hero-no-symbol"
  defp kind_icon("labeling_completed"), do: "hero-check-circle"
  defp kind_icon(_kind), do: "hero-bell"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:notifications}
    >
      <div class="flex items-start justify-between gap-2 flex-wrap">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Notifications")}</h1>
          <p class="opacity-70 mt-1">
            {gettext("Failures, regressions, and completions across the workspace.")}
          </p>
        </div>
        <button class="btn btn-ghost btn-sm" phx-click="mark_all_read">
          Mark all read
        </button>
      </div>

      <div class="flex gap-1 flex-wrap" id="kind-filters">
        <button
          :for={kind <- Notifications.kinds()}
          class={["btn btn-xs", (@kind == kind && "btn-primary") || "btn-ghost"]}
          phx-click="filter_kind"
          phx-value-kind={kind}
        >
          {String.replace(kind, "_", " ")}
        </button>
      </div>

      <div class="card border border-base-200 p-6 space-y-1" id="notifications-card">
        <p :if={@notifications == []} class="text-sm opacity-60">
          All quiet on the temporal front — nothing to report.
        </p>

        <div
          :for={notification <- @notifications}
          class={[
            "flex items-center gap-3 py-2 border-b border-base-200 last:border-0",
            notification.read_at != nil && "opacity-50"
          ]}
          id={"notification-#{notification.id}"}
        >
          <.icon name={kind_icon(notification.kind)} class="size-4 shrink-0 opacity-70" />
          <div class="min-w-0 flex-1">
            <.link
              :if={notification.path}
              navigate={notification.path}
              class="text-sm link-hover block truncate"
            >
              {notification.title}
            </.link>
            <span :if={!notification.path} class="text-sm block truncate">
              {notification.title}
            </span>
          </div>
          <span class="text-xs opacity-50 whitespace-nowrap">
            {Calendar.strftime(notification.inserted_at, "%m-%d %H:%M")}
          </span>
          <button
            :if={notification.read_at == nil}
            class="btn btn-ghost btn-xs"
            phx-click="mark_read"
            phx-value-id={notification.id}
            title="Mark read"
            aria-label="Mark this notification read"
          >
            <.icon name="hero-check" class="size-3" />
          </button>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
