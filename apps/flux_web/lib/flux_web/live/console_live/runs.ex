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
       share_url: nil,
       run_comments: [],
       compare_ids: [],
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

  # Palette deep links land here: ?run=<id> expands that run on load.
  @impl true
  def handle_params(%{"run" => run_id}, _uri, socket) do
    {:noreply,
     assign(socket,
       expanded_run: run_id,
       run_comments: load_comments(socket, run_id)
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      %{}
      |> put_filter(:workflow_id, params["workflow_id"])
      |> put_filter(:source, parse_enum(params["source"], @sources))
      |> put_filter(:status, parse_enum(params["status"], @statuses))
      |> put_filter(:from, parse_date(params["from"]))
      |> put_filter(:to, parse_date(params["to"]))
      |> put_filter(:q, String.trim(to_string(params["q"] || "")))
      |> put_filter(:tag, String.trim(to_string(params["tag"] || "")))

    {:noreply,
     socket
     |> assign(filters: filters, expanded_run: nil, limit: @page_size)
     |> load_runs()}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> update(:limit, &(&1 + @page_size)) |> load_runs()}
  end

  def handle_event("toggle_run", %{"id" => id}, socket) do
    expanded = (socket.assigns.expanded_run == id && nil) || id

    {:noreply,
     assign(socket,
       expanded_run: expanded,
       share_url: nil,
       run_comments: load_comments(socket, expanded)
     )}
  end

  def handle_event("set_tags", %{"run_id" => run_id, "tags" => tags_text}, socket) do
    tags = tags_text |> to_string() |> String.split(",")

    case Workflows.set_run_tags(socket.assigns.current_scope, run_id, tags) do
      {:ok, _run} ->
        {:noreply, load_runs(socket)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to tag runs.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the tags.")}
    end
  end

  def handle_event("post_comment", %{"run_id" => run_id, "body" => body}, socket) do
    case Workflows.add_run_comment(socket.assigns.current_scope, run_id, body) do
      {:ok, _comment} ->
        {:noreply, assign(socket, run_comments: load_comments(socket, run_id))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to comment on runs.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not post the comment.")}
    end
  end

  def handle_event("delete_comment", %{"id" => id}, socket) do
    case Workflows.delete_run_comment(socket.assigns.current_scope, id) do
      {:ok, _deleted} ->
        {:noreply,
         assign(socket, run_comments: load_comments(socket, socket.assigns.expanded_run))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only the author or an owner can delete a comment.")}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("share_run", %{"id" => id}, socket) do
    token = FluxWeb.RunShareController.sign(id)
    {:noreply, assign(socket, share_url: url(~p"/share/runs/#{token}"))}
  end

  # Pick up to two runs; the newest pick displaces the oldest.
  def handle_event("toggle_compare", %{"id" => id}, socket) do
    ids =
      if id in socket.assigns.compare_ids do
        List.delete(socket.assigns.compare_ids, id)
      else
        Enum.take(socket.assigns.compare_ids ++ [id], -2)
      end

    {:noreply, assign(socket, compare_ids: ids)}
  end

  def handle_event("clear_compare", _params, socket) do
    {:noreply, assign(socket, compare_ids: [])}
  end

  def handle_event("replay", %{"run-id" => run_id, "node-id" => node_id}, socket) do
    case Workflows.replay_run(socket.assigns.current_scope, run_id, node_id) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Replaying from that node — upstream outputs are reused, not re-paid."
         )
         |> load_runs()}

      {:error, :not_finished} ->
        {:noreply, put_flash(socket, :error, "Only finished runs can be replayed.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not replay from that node.")}
    end
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

  defp node_tokens(run, node_id) do
    case run.usage["by_node"] do
      %{^node_id => usage} ->
        (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)

      _untracked ->
        "—"
    end
  end

  # The waterfall: each node's bar scales to the slowest node (min 2% so
  # instant nodes stay visible).
  defp load_comments(_socket, nil), do: []

  defp load_comments(socket, run_id),
    do: Workflows.list_run_comments(socket.assigns.current_scope, run_id)

  defp bar_width(node_execution, node_executions) do
    slowest =
      node_executions
      |> Enum.map(&(&1["elapsed_ms"] || 0))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    max(round((node_execution["elapsed_ms"] || 0) / slowest * 100), 2)
  end

  # The two picked rows, oldest pick first; nil until both still visible.
  defp compare_rows(rows, [_id1, _id2] = ids) do
    picked = for id <- ids, row = Enum.find(rows, &(&1.run.id == id)), do: row
    if length(picked) == 2, do: picked
  end

  defp compare_rows(_rows, _ids), do: nil

  # Union of node ids across both runs, in first-appearance order, so the
  # side-by-side table lines up even when branches diverge.
  defp compare_node_ids(runs) do
    runs
    |> Enum.flat_map(& &1.node_executions)
    |> Enum.map(& &1["node_id"])
    |> Enum.uniq()
  end

  defp node_execution(run, node_id) do
    Enum.find(run.node_executions, &(&1["node_id"] == node_id))
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
            <input
              type="search"
              name="q"
              value={@filters[:q]}
              placeholder="search inputs/outputs…"
              class="input input-bordered input-sm w-48"
              phx-debounce="400"
            />
            <input
              type="search"
              name="tag"
              value={@filters[:tag]}
              placeholder="tag"
              class="input input-bordered input-sm w-28"
              phx-debounce="400"
            />
          </form>

          <a
            href={~p"/console/runs-export"}
            class="btn btn-ghost btn-xs ml-auto"
            title="Download recent runs with per-node traces as JSONL"
          >
            <.icon name="hero-arrow-down-tray" class="size-3" /> JSONL
          </a>
          <span class="text-xs opacity-60" id="runs-totals">
            {length(@rows)} runs · {@totals.tokens} tokens
            <span :if={@totals.cost > 0}>
              · ~${:erlang.float_to_binary(@totals.cost, decimals: 4)} est.
            </span>
          </span>
        </div>

        <p :if={@rows == []} class="text-sm opacity-60">
          Nothing matches — loosen the filters or run a flux.
        </p>

        <p :if={length(@compare_ids) == 1} class="text-xs opacity-60" id="compare-hint">
          Pick one more run to compare side by side.
        </p>

        <%= if compared = compare_rows(@rows, @compare_ids) do %>
          <div class="border border-primary/40 rounded-lg p-4 space-y-3" id="run-compare">
            <div class="flex items-center gap-2">
              <h3 class="font-semibold text-sm">Run comparison</h3>
              <button class="btn btn-ghost btn-xs ml-auto" phx-click="clear_compare">
                Clear
              </button>
            </div>

            <div class="grid grid-cols-2 gap-4 text-xs">
              <div :for={row <- compared} class="space-y-1 min-w-0">
                <p class="font-semibold">
                  {row.workflow_name}
                  <span class="opacity-60">
                    · {Calendar.strftime(row.run.inserted_at, "%m-%d %H:%M:%S")}
                  </span>
                </p>
                <p>
                  <span class={[
                    "badge badge-sm",
                    row.run.status == :succeeded && "badge-success",
                    row.run.status == :failed && "badge-error"
                  ]}>
                    {row.run.status}
                  </span>
                  <span class="badge badge-ghost badge-sm">{row.run.source}</span>
                  <span :if={row.run.version} class="badge badge-ghost badge-sm">
                    v{row.run.version}
                  </span>
                  · {row.run.elapsed_ms} ms · {run_tokens(row.run)} tokens
                </p>
                <p class="font-mono break-all">
                  <span class="font-semibold font-sans">In:</span> {summarize(row.run.inputs)}
                </p>
                <p class="font-mono break-all">
                  <span class="font-semibold font-sans">Out:</span> {summarize(row.run.outputs)}
                </p>
                <p :if={row.run.error} class="text-error font-mono">{row.run.error}</p>
              </div>
            </div>

            <table class="table table-xs">
              <thead>
                <tr>
                  <th>Node</th>
                  <th>ms (A)</th>
                  <th>ms (B)</th>
                  <th>Tokens (A)</th>
                  <th>Tokens (B)</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={node_id <- compare_node_ids(Enum.map(compared, & &1.run))}>
                  <% [a, b] = Enum.map(compared, &node_execution(&1.run, node_id)) %>
                  <td class="font-mono">
                    {(a || b)["title"] || node_id}
                  </td>
                  <td class="opacity-70">{(a && a["elapsed_ms"]) || "—"}</td>
                  <td class="opacity-70">{(b && b["elapsed_ms"]) || "—"}</td>
                  <td class="font-mono">
                    {(a && node_tokens(Enum.at(compared, 0).run, node_id)) || "—"}
                  </td>
                  <td class="font-mono">
                    {(b && node_tokens(Enum.at(compared, 1).run, node_id)) || "—"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>

        <table :if={@rows != []} class="table table-sm">
          <thead>
            <tr>
              <th title="Pick two runs to compare">⇄</th>

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
                <td onclick="event.stopPropagation()">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-xs"
                    checked={run.id in @compare_ids}
                    phx-click="toggle_compare"
                    phx-value-id={run.id}
                    aria-label="Pick this run for comparison"
                  />
                </td>

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
                <td colspan="8" class="bg-base-200/30">
                  <div class="space-y-2 p-2 text-xs">
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="rerun"
                      phx-value-id={run.id}
                      title="Start a new run with these inputs against the current draft"
                    >
                      <.icon name="hero-arrow-path" class="size-3" /> Re-run
                    </button>
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="share_run"
                      phx-value-id={run.id}
                      title="Create a read-only share link (30-day expiry, no console access needed)"
                    >
                      <.icon name="hero-link" class="size-3" /> Share trace
                    </button>
                    <a
                      href={~p"/console/runs/#{run.id}/export"}
                      class="btn btn-ghost btn-xs"
                      title="Download this run as JSON (inputs, outputs, per-node trace)"
                    >
                      <.icon name="hero-arrow-down-tray" class="size-3" /> JSON
                    </a>
                    <input
                      :if={@share_url && @expanded_run == run.id}
                      type="text"
                      readonly
                      value={@share_url}
                      class="input input-bordered input-xs w-96 font-mono"
                      onclick="this.select()"
                      id={"share-url-#{run.id}"}
                    />
                    <p :if={run.started_by} class="opacity-70">
                      <span class="font-semibold">Started by:</span> {run.started_by}
                    </p>
                    <p :if={run.error} class="text-error font-mono">{run.error}</p>

                    <p :if={run.inputs != %{}}>
                      <span class="font-semibold">Inputs:</span>
                      <span class="font-mono">{Jason.encode!(run.inputs)}</span>
                    </p>

                    <p :if={run.outputs != %{}}>
                      <span class="font-semibold">Outputs:</span>
                      <span class="font-mono break-all">{summarize(run.outputs)}</span>
                    </p>

                    <table :if={run.node_executions != []} class="table table-xs max-w-4xl">
                      <thead>
                        <tr>
                          <th>Node</th>

                          <th>Status</th>

                          <th>ms</th>

                          <th>Tokens</th>

                          <th class="w-48">Timeline</th>

                          <th>Outputs</th>

                          <th></th>
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

                          <td class="font-mono">
                            {node_tokens(run, node_execution["node_id"])}
                          </td>

                          <td>
                            <div
                              class={[
                                "h-2 rounded",
                                (node_execution["status"] == "failed" && "bg-error/70") ||
                                  "bg-primary/60"
                              ]}
                              style={"width: #{bar_width(node_execution, run.node_executions)}%"}
                              title={"#{node_execution["elapsed_ms"]} ms"}
                            >
                            </div>
                          </td>

                          <td class="font-mono break-all max-w-md">
                            {summarize(node_execution["outputs"] || %{})}
                          </td>

                          <td>
                            <button
                              :if={run.status in [:succeeded, :failed]}
                              class="btn btn-ghost btn-xs"
                              phx-click="replay"
                              phx-value-run-id={run.id}
                              phx-value-node-id={node_execution["node_id"]}
                              title="Replay from this node — upstream outputs are reused"
                              aria-label="Replay from this node"
                            >
                              <.icon name="hero-play" class="size-3" />
                            </button>
                          </td>
                        </tr>
                      </tbody>
                    </table>

                    <form
                      phx-submit="set_tags"
                      id={"run-tags-form-#{run.id}"}
                      class="flex gap-2 items-center flex-wrap"
                    >
                      <input type="hidden" name="run_id" value={run.id} />
                      <span :for={tag <- run.tags} class="badge badge-outline badge-sm">{tag}</span>
                      <input
                        type="text"
                        name="tags"
                        value={Enum.join(run.tags, ", ")}
                        placeholder="tags, comma-separated"
                        autocomplete="off"
                        class="input input-bordered input-xs w-56"
                      />
                      <button class="btn btn-ghost btn-xs">Save tags</button>
                    </form>

                    <div
                      class="border-t border-base-300 pt-2 space-y-1 max-w-2xl"
                      id={"run-comments-#{run.id}"}
                    >
                      <p class="font-semibold">Comments</p>
                      <div
                        :for={comment <- @run_comments}
                        class="flex items-start gap-2"
                        id={"run-comment-#{comment.id}"}
                      >
                        <span class="opacity-60 shrink-0">
                          {(comment.account && comment.account.email) || "removed account"} · {Calendar.strftime(
                            comment.inserted_at,
                            "%b %d %H:%M"
                          )}
                        </span>
                        <span class="whitespace-pre-wrap break-words">{comment.body}</span>
                        <button
                          class="btn btn-ghost btn-xs text-error ml-auto"
                          phx-click="delete_comment"
                          phx-value-id={comment.id}
                          aria-label="Delete comment"
                        >
                          <.icon name="hero-x-mark" class="size-3" />
                        </button>
                      </div>
                      <form
                        phx-submit="post_comment"
                        id={"run-comment-form-#{run.id}"}
                        class="flex gap-2 items-center"
                      >
                        <input type="hidden" name="run_id" value={run.id} />
                        <input
                          type="text"
                          name="body"
                          placeholder="Leave a note for the team…"
                          autocomplete="off"
                          class="input input-bordered input-xs flex-1"
                          required
                        />
                        <button class="btn btn-primary btn-xs">Post</button>
                      </form>
                    </div>
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
