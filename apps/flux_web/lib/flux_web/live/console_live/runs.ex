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
  @page_size 100

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
       statuses: @statuses,
       expanded_run: nil,
       limit: @page_size,
       flux_costs: Flux.Usage.flux_costs(scope)
     )
     |> load_runs()}
  end

  defp load_runs(socket) do
    rows =
      Workflows.list_workspace_runs(
        socket.assigns.current_scope,
        socket.assigns.filters,
        socket.assigns.limit
      )

    totals =
      Enum.reduce(rows, %{tokens: 0, cost: 0.0}, fn %{run: run}, acc ->
        %{
          tokens:
            acc.tokens + (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0),
          cost: acc.cost + (run.usage["estimated_cost_usd"] || 0.0)
        }
      end)

    assign(socket, rows: rows, totals: totals, more?: length(rows) >= socket.assigns.limit)
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      %{}
      |> put_filter(:workflow_id, params["workflow_id"])
      |> put_filter(:source, parse_enum(params["source"], @sources))
      |> put_filter(:status, parse_enum(params["status"], @statuses))
      |> put_filter(:from, parse_date(params["from"]))
      |> put_filter(:to, parse_date(params["to"]))

    {:noreply,
     socket
     |> assign(filters: filters, expanded_run: nil, limit: @page_size)
     |> load_runs()}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> update(:limit, &(&1 + @page_size)) |> load_runs()}
  end

  def handle_event("toggle_run", %{"id" => id}, socket) do
    {:noreply, assign(socket, expanded_run: (socket.assigns.expanded_run == id && nil) || id)}
  end

  def handle_event("rerun", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %{run: run} <- Enum.find(socket.assigns.rows, &(&1.run.id == id)),
         workflow when not is_tuple(workflow) <- Workflows.get_workflow(scope, run.workflow_id),
         {:ok, _new_run} <- Workflows.start_run(scope, workflow, run.inputs) do
      {:noreply,
       socket
       |> put_flash(:info, "Re-run started with the same inputs (against the current draft).")
       |> load_runs()}
    else
      {:error, :budget_exhausted} ->
        {:noreply, put_flash(socket, :error, "The monthly token budget is spent.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not re-run — flux gone or graph invalid.")}
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(to_string(value || "")) do
      {:ok, date} -> date
      _invalid -> nil
    end
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

  @summary_cap 300

  defp summarize(map) do
    encoded = Jason.encode!(map)

    if String.length(encoded) > @summary_cap do
      String.slice(encoded, 0, @summary_cap) <> "…"
    else
      encoded
    end
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
        <h1 class="text-2xl font-bold">{gettext("Runs")}</h1>

        <p class="opacity-70 mt-1">Every execution across the workspace — drafts, API calls, batches,
          and evals.</p>
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
            <input
              type="date"
              name="from"
              value={@filters[:from]}
              class="input input-bordered input-sm"
              title="From date"
            />
            <input
              type="date"
              name="to"
              value={@filters[:to]}
              class="input input-bordered input-sm"
              title="To date"
            />
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
            <%= for %{run: run, workflow_name: workflow_name} <- @rows do %>
              <tr
                id={"run-#{run.id}"}
                class="cursor-pointer hover:bg-base-200/40"
                phx-click="toggle_run"
                phx-value-id={run.id}
              >
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

              <tr :if={@expanded_run == run.id} id={"run-detail-#{run.id}"}>
                <td colspan="6" class="bg-base-200/30">
                  <div class="space-y-2 p-2 text-xs">
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="rerun"
                      phx-value-id={run.id}
                      title="Start a new run with these inputs against the current draft"
                    >
                      <.icon name="hero-arrow-path" class="size-3" /> Re-run
                    </button>
                    <p :if={run.error} class="text-error font-mono">{run.error}</p>

                    <p :if={run.inputs != %{}}>
                      <span class="font-semibold">Inputs:</span>
                      <span class="font-mono">{Jason.encode!(run.inputs)}</span>
                    </p>

                    <p :if={run.outputs != %{}}>
                      <span class="font-semibold">Outputs:</span>
                      <span class="font-mono break-all">{summarize(run.outputs)}</span>
                    </p>

                    <table :if={run.node_executions != []} class="table table-xs max-w-3xl">
                      <thead>
                        <tr>
                          <th>Node</th>

                          <th>Status</th>

                          <th>ms</th>

                          <th>Outputs</th>
                        </tr>
                      </thead>

                      <tbody>
                        <tr :for={node_execution <- run.node_executions}>
                          <td class="font-mono">
                            {node_execution["title"] || node_execution["node_id"]}
                          </td>

                          <td>
                            <span class={[
                              "badge badge-xs",
                              node_execution["status"] == "succeeded" && "badge-success",
                              node_execution["status"] == "failed" && "badge-error"
                            ]}>
                              {node_execution["status"]}
                            </span>
                          </td>

                          <td class="opacity-70">{node_execution["elapsed_ms"]}</td>

                          <td class="font-mono break-all max-w-md">
                            {summarize(node_execution["outputs"] || %{})}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <button :if={@more?} class="btn btn-ghost btn-sm" phx-click="load_more">
          Load more
        </button>
      </div>

      <div
        :if={@flux_costs != []}
        class="card border border-base-200 p-6 space-y-3"
        id="flux-costs-card"
      >
        <div class="flex items-center gap-2">
          <h2 class="font-semibold">Cost by flux (30 days)</h2>
          <a href={~p"/console/usage-export"} class="btn btn-ghost btn-xs ml-auto">
            <.icon name="hero-arrow-down-tray" class="size-3" /> Export CSV
          </a>
        </div>
        <table class="table table-xs max-w-2xl">
          <thead>
            <tr>
              <th>Flux</th>
              <th>Runs</th>
              <th>Tokens</th>
              <th>Est. cost</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @flux_costs} id={"cost-#{row.workflow_id}"}>
              <td>
                <.link navigate={~p"/console/fluxes/#{row.workflow_id}"} class="link link-hover">
                  {row.name}
                </.link>
              </td>
              <td class="text-xs">{row.runs}</td>
              <td class="font-mono text-xs">{row.tokens}</td>
              <td class="font-mono text-xs">
                <span :if={row.cost > 0}>
                  ~${:erlang.float_to_binary(row.cost * 1.0, decimals: 4)}
                </span>
                <span :if={row.cost == 0} class="opacity-40">—</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
