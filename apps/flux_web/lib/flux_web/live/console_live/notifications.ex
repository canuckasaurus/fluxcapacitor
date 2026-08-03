defmodule FluxWeb.ConsoleLive.Notifications do
  @moduledoc """
  The workspace notification feed: run failures, gate/eval regressions,
  and labeling completions. Opening the page marks everything read.
  """
  use FluxWeb, :live_view

  alias Flux.Notifications

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Notifications.subscribe(scope.workspace.id)
      Notifications.mark_all_read(scope)
    end

    {:ok,
     assign(socket,
       page_title: "Notifications",
       notifications: Notifications.list(scope)
     )}
  end

  @impl true
  def handle_info(:notifications_changed, socket) do
    scope = socket.assigns.current_scope
    Notifications.mark_all_read(scope)
    {:noreply, assign(socket, notifications: Notifications.list(scope))}
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
      <div>
        <h1 class="text-2xl font-bold">{gettext("Notifications")}</h1>
        <p class="opacity-70 mt-1">
          {gettext("Failures, regressions, and completions across the workspace.")}
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-1" id="notifications-card">
        <p :if={@notifications == []} class="text-sm opacity-60">
          All quiet on the temporal front — nothing to report.
        </p>

        <div
          :for={notification <- @notifications}
          class="flex items-center gap-3 py-2 border-b border-base-200 last:border-0"
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
        </div>
      </div>
    </Layouts.console>
    """
  end
end
