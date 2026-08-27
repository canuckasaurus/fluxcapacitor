defmodule FluxWeb.ConsoleLive.Inbox do
  @moduledoc """
  The pending-work inbox: everything in the workspace waiting on a
  human, in one place — paused runs (human input, tool approvals,
  interviews, labeling nodes), the labeling queue, and each app's
  handoff queue. Each row links to where the work gets done.
  """
  use FluxWeb, :live_view

  alias Flux.Chat
  alias Flux.Workflows

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if Flux.RBAC.can?(scope, :app_monitor) do
      mount_inbox(scope, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view the inbox.")
       |> push_navigate(to: ~p"/console")}
    end
  end

  defp mount_inbox(scope, socket) do
    handoff_queues =
      for app <- Chat.list_apps(scope),
          queue = Chat.handoff_queue(scope, app.id),
          queue != [] do
        %{app: app, waiting: length(queue), oldest: List.first(queue)}
      end

    {:ok,
     assign(socket,
       page_title: "Inbox",
       paused: Workflows.list_paused_runs(scope),
       handoff_queues: handoff_queues,
       labeling_depth: labeling_depth(scope)
     )}
  end

  defp labeling_depth(scope) do
    import Ecto.Query, only: [where: 3]

    Flux.Labeling.Task
    |> Flux.Repo.scoped(scope)
    |> where([t], t.status == :unlabeled)
    |> Flux.Repo.aggregate(:count)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:inbox}
    >
      <div>
        <h1 class="text-2xl font-bold">{gettext("Inbox")}</h1>
        <p class="opacity-70 mt-1">
          Everything waiting on a human — paused runs, handoffs, and the
          labeling queue.
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="paused-runs-card">
        <h2 class="font-semibold">
          Paused runs ({length(@paused)})
        </h2>
        <p :if={@paused == []} class="text-sm opacity-60">
          Nothing is waiting — every run is moving on its own.
        </p>
        <table :if={@paused != []} class="table table-sm">
          <thead>
            <tr>
              <th>Flux</th>
              <th>Waiting on</th>
              <th>Since</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @paused} id={"inbox-run-#{entry.run.id}"}>
              <td class="font-semibold">{entry.workflow_name}</td>
              <td>
                <span class="badge badge-warning badge-sm">{entry.waiting_on}</span>
              </td>
              <td class="text-xs opacity-70">
                {Calendar.strftime(entry.run.updated_at, "%Y-%m-%d %H:%M")} UTC
              </td>
              <td>
                <.link
                  :if={entry.run.workflow_id}
                  navigate={~p"/console/fluxes/#{entry.run.workflow_id}"}
                  class="btn btn-outline btn-xs"
                  title="The paused run resumes from the flux's run panel"
                >
                  Open flux
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="inbox-handoffs-card">
        <h2 class="font-semibold">Visitors waiting for a human</h2>
        <p :if={@handoff_queues == []} class="text-sm opacity-60">
          No open handoffs anywhere.
        </p>
        <p :for={entry <- @handoff_queues} class="text-sm flex items-center gap-2">
          <span class="font-semibold">{entry.app.name}</span>
          <span class="badge badge-warning badge-sm">{entry.waiting} waiting</span>
          <span :if={entry.oldest.handoff_requested_at} class="text-xs opacity-60">
            oldest since {Calendar.strftime(entry.oldest.handoff_requested_at, "%H:%M")} UTC
          </span>
          <.link navigate={~p"/console/apps/#{entry.app.id}/monitor"} class="btn btn-outline btn-xs">
            Open monitor
          </.link>
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="inbox-labeling-card">
        <h2 class="font-semibold">Labeling queue</h2>
        <p class="text-sm">
          <span class="badge badge-ghost badge-sm">{@labeling_depth} unlabeled task(s)</span>
          <.link navigate={~p"/console/labeling"} class="btn btn-outline btn-xs ml-2">
            Open labeling
          </.link>
        </p>
      </div>
    </Layouts.console>
    """
  end
end
