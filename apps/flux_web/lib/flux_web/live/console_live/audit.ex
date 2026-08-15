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
         from: nil,
         to: nil,
         actor_id: nil,
         members: for({account, _membership} <- Flux.Accounts.list_members(scope), do: account),
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
  def handle_event("filter", %{"from" => from, "to" => to} = params, socket) do
    from = parse_date(from)
    to = parse_date(to)
    actor_id = ((params["actor"] || "") != "" && params["actor"]) || nil

    {:noreply,
     assign(socket,
       from: from,
       to: to,
       actor_id: actor_id,
       entries:
         Audit.list(socket.assigns.current_scope, 100,
           from: from,
           to: to,
           actor_id: actor_id
         )
     )}
  end

  defp parse_date(value) do
    case Date.from_iso8601(value || "") do
      {:ok, date} -> date
      _blank -> nil
    end
  end

  defp export_path(from, to, actor_id) do
    query =
      [
        {"from", from && Date.to_iso8601(from)},
        {"to", to && Date.to_iso8601(to)},
        {"actor", actor_id}
      ]
      |> Enum.reject(fn {_key, value} -> value == nil end)

    (query == [] && ~p"/console/audit-export") ||
      ~p"/console/audit-export?#{query}"
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

      <div class="flex flex-wrap items-end gap-2">
        <form phx-change="filter" id="audit-filter" class="flex items-end gap-2">
          <label class="form-control">
            <span class="label-text text-xs opacity-70">From</span>
            <input
              type="date"
              name="from"
              value={@from && Date.to_iso8601(@from)}
              class="input input-bordered input-sm"
            />
          </label>
          <label class="form-control">
            <span class="label-text text-xs opacity-70">To</span>
            <input
              type="date"
              name="to"
              value={@to && Date.to_iso8601(@to)}
              class="input input-bordered input-sm"
            />
          </label>
          <label class="form-control">
            <span class="label-text text-xs opacity-70">Actor</span>
            <select name="actor" class="select select-bordered select-sm">
              <option value="">Everyone</option>
              <option
                :for={member <- @members}
                value={member.id}
                selected={@actor_id == member.id}
              >
                {member.email}
              </option>
            </select>
          </label>
        </form>
        <a
          href={export_path(@from, @to, @actor_id)}
          class="btn btn-outline btn-sm"
          id="audit-export-link"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Download CSV
        </a>
      </div>

      <p :if={@entries == []} class="text-sm opacity-60">Nothing recorded in this window.</p>

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
