defmodule FluxWeb.ConsoleLive.Admin do
  @moduledoc """
  The instance admin panel (`FLUX_ADMIN_EMAILS` gates entry): every
  workspace on this deployment with plan, members, 30-day run volume,
  and a plan selector — the self-host operator's one screen.
  """
  use FluxWeb, :live_view

  alias Flux.Accounts

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.instance_admin?(socket.assigns.current_scope.account) do
      {:ok,
       assign(socket,
         page_title: "Instance admin",
         overview: Accounts.instance_overview(),
         plans: Flux.Features.plans()
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "The admin panel needs an instance admin account.")
       |> push_navigate(to: ~p"/console")}
    end
  end

  @impl true
  def handle_event("set_plan", %{"workspace-id" => workspace_id, "plan" => plan}, socket) do
    with true <- Accounts.instance_admin?(socket.assigns.current_scope.account),
         {:ok, _workspace} <- Flux.Features.set_plan_for_workspace(workspace_id, plan) do
      {:noreply,
       socket
       |> put_flash(:info, "Plan updated.")
       |> assign(overview: Accounts.instance_overview())}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not change the plan.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:admin}
    >
      <div>
        <h1 class="text-2xl font-bold">Instance admin</h1>
        <p class="opacity-70 mt-1">
          Every workspace on this deployment — plans, people, and 30-day volume.
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="admin-card">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Workspace</th>
              <th>Plan</th>
              <th>Members</th>
              <th>Runs (30d)</th>
              <th>Tokens (30d)</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @overview} id={"admin-ws-#{row.workspace.id}"}>
              <td class="font-semibold">{row.workspace.name}</td>
              <td>
                <form phx-change="set_plan">
                  <input type="hidden" name="workspace-id" value={row.workspace.id} />
                  <select name="plan" class="select select-bordered select-xs">
                    <option :for={plan <- @plans} value={plan} selected={row.plan == plan}>
                      {plan}
                    </option>
                  </select>
                </form>
              </td>
              <td class="text-xs">{row.members}</td>
              <td class="text-xs">{row.runs_30d}</td>
              <td class="font-mono text-xs">{row.tokens_30d}</td>
              <td class="text-xs opacity-70">
                {Calendar.strftime(row.workspace.inserted_at, "%Y-%m-%d")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
