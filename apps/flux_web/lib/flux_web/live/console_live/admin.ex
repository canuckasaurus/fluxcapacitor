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
         provider_health: Flux.ProviderHealth.stats(),
         recent_calls: Flux.ProviderHealth.recent(),
         queue_stats: Flux.Jobs.queue_stats(),
         problem_jobs: Flux.Jobs.problem_jobs(),
         archived: Accounts.archived_workspaces(),
         status_note: Flux.InstanceSettings.get("status_note"),
         announcement: Flux.InstanceSettings.get("announcement"),
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

  def handle_event("retry_job", %{"id" => id}, socket) do
    with true <- Accounts.instance_admin?(socket.assigns.current_scope.account),
         :ok <- Flux.Jobs.retry_job(String.to_integer(id)) do
      {:noreply, refresh_jobs(put_flash(socket, :info, "Job queued to retry."))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not retry that job.")}
    end
  end

  def handle_event("discard_job", %{"id" => id}, socket) do
    with true <- Accounts.instance_admin?(socket.assigns.current_scope.account),
         :ok <- Flux.Jobs.discard_job(String.to_integer(id)) do
      {:noreply, refresh_jobs(put_flash(socket, :info, "Job cancelled."))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not cancel that job.")}
    end
  end

  def handle_event("refresh_jobs", _params, socket) do
    {:noreply, refresh_jobs(socket)}
  end

  def handle_event("save_status_note", %{"note" => note}, socket) do
    with true <- Accounts.instance_admin?(socket.assigns.current_scope.account) do
      :ok = Flux.InstanceSettings.put("status_note", note)

      {:noreply,
       socket
       |> put_flash(:info, "Status note saved — it shows on /status.")
       |> assign(status_note: Flux.InstanceSettings.get("status_note"))}
    else
      _not_admin -> {:noreply, socket}
    end
  end

  def handle_event("save_announcement", %{"note" => note}, socket) do
    with true <- Accounts.instance_admin?(socket.assigns.current_scope.account) do
      :ok = Flux.InstanceSettings.put("announcement", note)

      {:noreply,
       socket
       |> put_flash(:info, "Announcement saved — it shows atop every console page.")
       |> assign(announcement: Flux.InstanceSettings.get("announcement"))}
    else
      _not_admin -> {:noreply, socket}
    end
  end

  def handle_event("restore_workspace", %{"workspace-id" => workspace_id}, socket) do
    with true <- Accounts.instance_admin?(socket.assigns.current_scope.account),
         {:ok, workspace} <- Accounts.restore_workspace(workspace_id) do
      {:noreply,
       socket
       |> put_flash(:info, "#{workspace.name} restored.")
       |> assign(archived: Accounts.archived_workspaces(), overview: Accounts.instance_overview())}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not restore that workspace.")}
    end
  end

  defp refresh_jobs(socket) do
    assign(socket,
      queue_stats: Flux.Jobs.queue_stats(),
      problem_jobs: Flux.Jobs.problem_jobs()
    )
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1_024, do: "#{div(bytes, 1024)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

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
              <th>Storage</th>
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
              <td class="font-mono text-xs">{format_bytes(row.storage_bytes)}</td>
              <td class="text-xs opacity-70">
                {Calendar.strftime(row.workspace.inserted_at, "%Y-%m-%d")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="provider-health">
        <h2 class="font-semibold">Provider health (since boot)</h2>
        <p :if={@provider_health == []} class="text-sm opacity-60">
          No model calls yet.
        </p>
        <table :if={@provider_health != []} class="table table-sm max-w-xl">
          <thead>
            <tr>
              <th>Provider</th>
              <th>Calls</th>
              <th>Errors</th>
              <th>Error rate</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @provider_health}>
              <td class="font-mono text-xs">{row.provider}</td>
              <td>{row.calls}</td>
              <td class={row.errors > 0 && "text-error"}>{row.errors}</td>
              <td>
                <span class={[
                  "badge badge-sm",
                  (row.error_rate > 10 && "badge-error") || "badge-ghost"
                ]}>
                  {row.error_rate}%
                </span>
              </td>
            </tr>
          </tbody>
        </table>

        <details :if={@recent_calls != []} id="recent-provider-calls">
          <summary class="text-xs opacity-60 cursor-pointer">
            Recent calls ({length(@recent_calls)})
          </summary>
          <table class="table table-xs max-w-2xl mt-2">
            <thead>
              <tr>
                <th>When</th>
                <th>Provider</th>
                <th>Model</th>
                <th>Latency</th>
                <th>Outcome</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={call <- @recent_calls}>
                <td class="text-xs opacity-60">{Calendar.strftime(call.at, "%H:%M:%S")}</td>
                <td class="font-mono text-xs">{call.provider}</td>
                <td class="font-mono text-xs">{call.model}</td>
                <td class="font-mono text-xs">{call.latency_ms}ms</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    (call.outcome == :ok && "badge-success") || "badge-error"
                  ]}>
                    {call.outcome}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </details>
      </div>
      <div class="card border border-base-200 p-6 space-y-2" id="status-note-card">
        <h2 class="font-semibold">Status page incident note</h2>
        <p class="text-sm opacity-70">
          Shown on the public <a href="/status" class="link">/status</a>
          page while non-blank — for planned maintenance and incident updates.
        </p>
        <form phx-submit="save_status_note" id="status-note-form" class="space-y-2">
          <textarea
            name="note"
            rows="2"
            placeholder="e.g. Provider X is degraded; replies may be slow."
            class="textarea textarea-bordered textarea-sm w-full max-w-xl"
          >{@status_note}</textarea>
          <button class="btn btn-primary btn-sm">Save note</button>
        </form>
      </div>

      <div class="card border border-base-200 p-6 space-y-2" id="announcement-card">
        <h2 class="font-semibold">Console announcement</h2>
        <p class="text-sm opacity-70">
          Shown as a banner atop every console page while non-blank — for
          maintenance windows and migration notices. Blank to clear.
        </p>
        <form phx-submit="save_announcement" id="announcement-form" class="space-y-2">
          <textarea
            name="note"
            rows="2"
            placeholder="e.g. Scheduled maintenance Saturday 02:00–03:00 UTC."
            class="textarea textarea-bordered textarea-sm w-full max-w-xl"
          >{@announcement}</textarea>
          <button class="btn btn-primary btn-sm">Save announcement</button>
        </form>
      </div>

      <div
        :if={@archived != []}
        class="card border border-base-200 p-6 space-y-2"
        id="archived-workspaces"
      >
        <h2 class="font-semibold">Archived workspaces</h2>
        <div :for={workspace <- @archived} class="flex items-center gap-3 text-sm">
          <.icon name="hero-archive-box" class="size-4 opacity-60" />
          <span class="font-semibold">{workspace.name}</span>
          <span class="text-xs opacity-60">
            archived {Calendar.strftime(workspace.updated_at, "%Y-%m-%d")}
          </span>
          <button
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="restore_workspace"
            phx-value-workspace-id={workspace.id}
          >
            Restore
          </button>
        </div>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="background-jobs">
        <div class="flex items-center justify-between">
          <h2 class="font-semibold">Background jobs</h2>
          <button class="btn btn-ghost btn-xs" phx-click="refresh_jobs">Refresh</button>
        </div>

        <p :if={@queue_stats == []} class="text-sm opacity-60">No jobs recorded yet.</p>

        <table :if={@queue_stats != []} class="table table-xs max-w-2xl">
          <thead>
            <tr>
              <th>Queue</th>
              <th>Available</th>
              <th>Executing</th>
              <th>Scheduled</th>
              <th>Retryable</th>
              <th>Discarded</th>
              <th>Completed</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @queue_stats}>
              <td class="font-mono text-xs">{row.queue}</td>
              <td>{row.available}</td>
              <td>{row.executing}</td>
              <td>{row.scheduled}</td>
              <td class={row.retryable > 0 && "text-warning font-semibold"}>{row.retryable}</td>
              <td class={row.discarded > 0 && "text-error font-semibold"}>{row.discarded}</td>
              <td class="opacity-60">{row.completed}</td>
            </tr>
          </tbody>
        </table>

        <div :if={@problem_jobs != []} class="space-y-2">
          <h3 class="text-sm font-semibold">Needs attention</h3>
          <div
            :for={job <- @problem_jobs}
            class="flex items-start gap-2 text-xs border-b border-base-200 last:border-0 py-2"
            id={"job-#{job.id}"}
          >
            <span class={[
              "badge badge-xs mt-0.5",
              (job.state == "discarded" && "badge-error") || "badge-warning"
            ]}>
              {job.state}
            </span>
            <div class="min-w-0 flex-1">
              <p class="font-mono truncate">{job.worker}</p>
              <p class="opacity-60">
                {job.queue} · attempt {job.attempt}/{job.max_attempts}
                <span :if={job.attempted_at}>
                  · {Calendar.strftime(job.attempted_at, "%m-%d %H:%M:%S")}
                </span>
              </p>
              <p :if={job.last_error} class="text-error/80 truncate" title={job.last_error}>
                {job.last_error}
              </p>
            </div>
            <button class="btn btn-ghost btn-xs" phx-click="retry_job" phx-value-id={job.id}>
              Retry
            </button>
            <button
              class="btn btn-ghost btn-xs text-error"
              phx-click="discard_job"
              phx-value-id={job.id}
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
