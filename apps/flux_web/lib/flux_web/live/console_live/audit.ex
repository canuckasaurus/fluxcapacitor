defmodule FluxWeb.ConsoleLive.Audit do
  @moduledoc "Browsing UI for the workspace audit trail (owners/admins)."
  use FluxWeb, :live_view

  alias Flux.Audit
  alias Flux.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, :workspace_member_manage) do
      {:ok,
       assign(socket,
         page_title: "Audit log",
         entries: Audit.list(scope, 100)
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view the audit log.")
       |> push_navigate(to: ~p"/console")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:audit}
    >
      <div>
        <h1 class="text-2xl font-bold">{gettext("Audit log")}</h1>

        <p class="opacity-70 mt-1">Consequential actions in this workspace — most recent first.</p>
      </div>

      <p :if={@entries == []} class="text-sm opacity-60">Nothing recorded yet.</p>

      <table :if={@entries != []} class="table table-sm">
        <thead>
          <tr>
            <th>When</th>

            <th>Actor</th>

            <th>Action</th>

            <th>Resource</th>

            <th>Details</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={entry <- @entries} id={"audit-#{entry.id}"}>
            <td class="text-xs opacity-70 whitespace-nowrap">
              {Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M:%S")}
            </td>

            <td class="text-xs">{(entry.actor && entry.actor.email) || "system"}</td>

            <td><code class="text-xs">{entry.action}</code></td>

            <td class="text-xs opacity-70">
              {entry.resource_type}
              <span :if={entry.resource_id} class="font-mono opacity-60">
                {String.slice(entry.resource_id, 0, 8)}
              </span>
            </td>

            <td class="text-xs opacity-70">
              {(entry.metadata != %{} && Jason.encode!(entry.metadata)) || ""}
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.console>
    """
  end
end
