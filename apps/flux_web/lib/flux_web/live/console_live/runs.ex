defmodule FluxWeb.ConsoleLive.Runs do
  @moduledoc """
  Workspace-wide run history: every execution — interactive, API, batch,
  or eval — filterable by flux, source, and status, with token and
  estimated-cost totals over the visible slice.
  """
  use FluxWeb, :live_view

  alias Flux.Workflows

  @sources ~w(draft api batch eval)
  @statuses ~w(succeeded failed running paused stopped)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "Runs",
       workflow_options: Workflows.workflow_options(scope),
       filters: %{},
       sources: @sources,
       statuses: @statuses
     )
     |> load_runs()}
  end

  defp load_runs(socket) do
    rows =
      Workflows.list_workspace_runs(socket.assigns.current_scope, socket.assigns.filters)

    totals =
      Enum.reduce(rows, %{tokens: 0, cost: 0.0}, fn %{run: run}, acc ->
        %{
          tokens:
            acc.tokens + (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0),
          cost: acc.cost + (run.usage["estimated_cost_usd"] || 0.0)
        }
      end)

    assign(socket, rows: rows, totals: totals)
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      %{}
      |> put_filter(:workflow_id, params["workflow_id"])
      |> put_filter(:source, parse_enum(params["source"], @sources))
      |> put_filter(:status, parse_enum(params["status"], @statuses))

    {:noreply, socket |> assign(filters: filters) |> load_runs()}
  end

  defp put_filter(filters, _key, nil), do: filters
  defp put_filter(filters, _key, ""), do: filters
  defp put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp parse_enum(value, allowed) do
    if value in allowed, do: String.to_existing_atom(value), else: nil
  end

  defp run_tokens(run) do
    (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:runs}
    >
      <div>
        <h1 class="text-2xl font-bold">Runs</h1>
        <p class="opacity-70 mt-1">
          Every execution across the workspace — drafts, API calls, batches,
          and evals.
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="runs-card">
        <div class="flex flex-wrap items-center gap-2">
          <form phx-change="filter" id="runs-filter-form" class="flex flex-wrap gap-2">
            <select name="workflow_id" class="select select-bordered select-sm">
              <option value="">all fluxes</option>
              <option
                :for={{name, id} <- @workflow_options}
                value={id}
                selected={@filters[:workflow_id] == id}
              >
                {name}
              </option>
            </select>
            <select name="source" class="select select-bordered select-sm">
              <option value="">all sources</option>
              <option
                :for={source <- @sources}
                value={source}
                selected={to_string(@filters[:source]) == source}
              >
                {source}
              </option>
            </select>
            <select name="status" class="select select-bordered select-sm">
              <option value="">all statuses</option>
              <option
                :for={status <- @statuses}
                value={status}
                selected={to_string(@filters[:status]) == status}
              >
                {status}
              </option>
            </select>
          </form>
          <span class="text-xs opacity-60 ml-auto" id="runs-totals">
            {length(@rows)} runs · {@totals.tokens} tokens
            <span :if={@totals.cost > 0}>
              · ~${:erlang.float_to_binary(@totals.cost, decimals: 4)} est.
            </span>
          </span>
        </div>

        <p :if={@rows == []} class="text-sm opacity-60">
          Nothing matches — loosen the filters or run a flux.
        </p>

        <table :if={@rows != []} class="table table-sm">
          <thead>
            <tr>
              <th>When</th>
              <th>Flux</th>
              <th>Source</th>
              <th>Status</th>
              <th>Tokens</th>
              <th>ms</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={%{run: run, workflow_name: workflow_name} <- @rows} id={"run-#{run.id}"}>
              <td class="text-xs opacity-70">
                {Calendar.strftime(run.inserted_at, "%m-%d %H:%M:%S")}
              </td>
              <td>
                <.link navigate={~p"/console/fluxes/#{run.workflow_id}"} class="link link-hover">
                  {workflow_name}
                </.link>
              </td>
              <td><span class="badge badge-ghost badge-sm">{run.source}</span></td>
              <td>
                <span class={[
                  "badge badge-sm",
                  run.status == :succeeded && "badge-success",
                  run.status == :failed && "badge-error",
                  run.status == :running && "badge-info",
                  run.status == :paused && "badge-warning",
                  run.status == :stopped && "badge-warning"
                ]}>
                  {run.status}
                </span>
              </td>
              <td class="font-mono text-xs">{run_tokens(run)}</td>
              <td class="text-xs opacity-70">{run.elapsed_ms}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
