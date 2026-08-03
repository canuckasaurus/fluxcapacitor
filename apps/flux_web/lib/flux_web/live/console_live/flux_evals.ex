defmodule FluxWeb.ConsoleLive.FluxEvals do
  @moduledoc """
  Evaluations for one flux: build test-case sets (by hand, from CSV),
  run them against the draft or any published version with a chosen
  grader, and compare scores across passes.
  """
  use FluxWeb, :live_view

  alias Flux.Evals
  alias Flux.Workflows
  alias Flux.Workflows.Workflow

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow(scope, id) do
      %Workflow{} = workflow ->
        if connected?(socket), do: Evals.subscribe(workflow.id)

        sets = Evals.list_sets(scope, workflow.id)

        {:ok,
         socket
         |> assign(
           page_title: "Evaluations — #{workflow.name}",
           workflow: workflow,
           versions: Workflows.list_versions(scope, workflow.id),
           models: Flux.Providers.available_models(scope),
           sets: sets,
           selected_set: List.first(sets),
           expanded_eval: nil
         )
         |> assign_set_data()
         |> allow_upload(:cases_csv,
           accept: ~w(.csv .txt),
           max_entries: 1,
           max_file_size: 1_000_000
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Flux not found.")
         |> push_navigate(to: ~p"/console/fluxes")}
    end
  end

  defp assign_set_data(socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.selected_set do
      nil ->
        assign(socket, cases: [], eval_runs: [], recent_runs: [])

      set ->
        assign(socket,
          cases: Evals.list_cases(scope, set.id),
          eval_runs: Evals.list_eval_runs(scope, set.id),
          recent_runs: recent_succeeded_runs(scope, socket.assigns.workflow.id)
        )
    end
  end

  defp recent_succeeded_runs(scope, workflow_id) do
    scope
    |> Workflows.list_runs(workflow_id, 50)
    |> Enum.filter(&(&1.status == :succeeded))
    |> Enum.take(15)
  end

  defp reload_sets(socket, keep_id \\ nil) do
    scope = socket.assigns.current_scope
    sets = Evals.list_sets(scope, socket.assigns.workflow.id)
    selected = Enum.find(sets, List.first(sets), &(&1.id == keep_id))

    socket
    |> assign(sets: sets, selected_set: selected)
    |> assign_set_data()
  end

  @impl true
  def handle_event("create_set", %{"name" => name}, socket) do
    case Evals.create_set(socket.assigns.current_scope, socket.assigns.workflow, %{"name" => name}) do
      {:ok, set} ->
        {:noreply, socket |> put_flash(:info, "Set created.") |> reload_sets(set.id)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage evals.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Give the set a name.")}
    end
  end

  def handle_event("select_set", %{"id" => id}, socket) do
    {:noreply, socket |> assign(expanded_eval: nil) |> reload_sets(id)}
  end

  def handle_event("delete_set", %{"id" => id}, socket) do
    case Evals.delete_set(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Set deleted.") |> reload_sets()}
      _error -> {:noreply, put_flash(socket, :error, "Could not delete the set.")}
    end
  end

  def handle_event("add_case", %{"expected" => expected} = params, socket) do
    inputs = Map.get(params, "inputs", %{})

    case Evals.add_case(socket.assigns.current_scope, socket.assigns.selected_set, %{
           "inputs" => inputs,
           "expected" => expected
         }) do
      {:ok, _case} ->
        {:noreply, socket |> put_flash(:info, "Case added.") |> assign_set_data()}

      {:error, {:too_many_cases, max}} ->
        {:noreply, put_flash(socket, :error, "Sets cap at #{max} cases.")}

      _error ->
        {:noreply, put_flash(socket, :error, "The expected answer is required.")}
    end
  end

  def handle_event("add_case_from_run", %{"run_id" => run_id}, socket) do
    case Evals.add_case_from_run(
           socket.assigns.current_scope,
           socket.assigns.selected_set,
           run_id
         ) do
      {:ok, _case} ->
        {:noreply,
         socket
         |> put_flash(:info, "Case captured — the run's output is now the reference.")
         |> assign_set_data()}

      {:error, :not_succeeded} ->
        {:noreply, put_flash(socket, :error, "Only succeeded runs capture as cases.")}

      {:error, {:too_many_cases, max}} ->
        {:noreply, put_flash(socket, :error, "Sets cap at #{max} cases.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not capture that run.")}
    end
  end

  def handle_event("delete_case", %{"id" => id}, socket) do
    case Evals.delete_case(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, assign_set_data(socket)}
      _error -> {:noreply, put_flash(socket, :error, "Could not delete the case.")}
    end
  end

  def handle_event("validate_csv", _params, socket), do: {:noreply, socket}

  def handle_event("import_cases", _params, socket) do
    uploads =
      consume_uploaded_entries(socket, :cases_csv, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    with [text] <- uploads,
         {:ok, rows} <- Flux.CSV.parse_with_header(text),
         {:ok, cases} <-
           Evals.add_cases_from_rows(
             socket.assigns.current_scope,
             socket.assigns.selected_set,
             rows
           ) do
      {:noreply,
       socket |> put_flash(:info, "Imported #{length(cases)} cases.") |> assign_set_data()}
    else
      [] ->
        {:noreply, put_flash(socket, :error, "Choose a CSV file first.")}

      {:error, :missing_expected} ->
        {:noreply, put_flash(socket, :error, ~s(The CSV needs an "expected" column.))}

      {:error, {:too_many_cases, max}} ->
        {:noreply, put_flash(socket, :error, "Sets cap at #{max} cases.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That CSV could not be parsed.")}
    end
  end

  def handle_event("run_eval", %{"target" => target, "grader" => grader} = params, socket) do
    version =
      case target do
        "draft" -> nil
        "v" <> number -> String.to_integer(number)
      end

    judge =
      case params["judge"] do
        "default" -> nil
        judge -> judge
      end

    case Evals.start_eval(socket.assigns.current_scope, socket.assigns.selected_set,
           grader: grader,
           version: version,
           judge: judge
         ) do
      {:ok, _eval_run} ->
        {:noreply, socket |> put_flash(:info, "Evaluation started.") |> assign_set_data()}

      {:error, :no_cases} ->
        {:noreply, put_flash(socket, :error, "Add cases before running an evaluation.")}

      {:error, {:invalid_graph, [error | _]}} ->
        {:noreply, put_flash(socket, :error, "The target graph is invalid: #{error}")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not start the evaluation.")}
    end
  end

  def handle_event("toggle_gate", _params, socket) do
    set = socket.assigns.selected_set

    case Evals.set_gate(socket.assigns.current_scope, set.id, !set.gate) do
      {:ok, updated} ->
        message =
          if updated.gate do
            "Gate on — this set now scores every published version."
          else
            "Gate off."
          end

        {:noreply, socket |> put_flash(:info, message) |> reload_sets(updated.id)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the gate.")}
    end
  end

  def handle_event("set_schedule", %{"schedule" => schedule}, socket) do
    set = socket.assigns.selected_set

    case Evals.set_schedule(socket.assigns.current_scope, set.id, schedule) do
      {:ok, updated} ->
        message =
          if updated.schedule do
            "Scheduled — runs at `#{updated.schedule}` against the latest published version."
          else
            "Schedule cleared."
          end

        {:noreply, socket |> put_flash(:info, message) |> reload_sets(updated.id)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "That isn't a valid cron expression.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the schedule.")}
    end
  end

  def handle_event("toggle_results", %{"id" => id}, socket) do
    {:noreply, assign(socket, expanded_eval: (socket.assigns.expanded_eval == id && nil) || id)}
  end

  @impl true
  def handle_info({:eval_updated, _eval_run_id}, socket) do
    {:noreply, assign_set_data(socket)}
  end

  defp start_variables(workflow) do
    workflow.graph["nodes"]
    |> List.wrap()
    |> Enum.find(%{}, &(&1["type"] == "start"))
    |> get_in(["config", "variables"])
    |> List.wrap()
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
  end

  defp expanded_results(assigns) do
    Enum.find(assigns.eval_runs, &(&1.id == assigns.expanded_eval))
  end

  # Score delta vs the next-older completed run in the (desc-sorted) list.
  defp score_delta(eval_run, eval_runs) do
    with true <- eval_run.status == :completed and is_number(eval_run.avg_score),
         index = Enum.find_index(eval_runs, &(&1.id == eval_run.id)),
         %{avg_score: previous} when is_number(previous) <-
           eval_runs |> Enum.drop(index + 1) |> Enum.find(&(&1.status == :completed)) do
      Float.round((eval_run.avg_score - previous) * 100, 1)
    else
      _no_baseline -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:fluxes}
    >
      <div class="flex items-center gap-3">
        <.link navigate={~p"/console/fluxes/#{@workflow.id}"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="size-4" /> {@workflow.name}
        </.link>
        <h1 class="text-2xl font-bold">{gettext("Evaluations")}</h1>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="eval-sets-card">
        <h2 class="font-semibold">Eval sets</h2>
        <div class="flex flex-wrap items-center gap-2">
          <button
            :for={set <- @sets}
            class={[
              "btn btn-sm",
              (@selected_set && @selected_set.id == set.id && "btn-primary") || "btn-ghost"
            ]}
            phx-click="select_set"
            phx-value-id={set.id}
          >
            {set.name}
          </button>
          <form phx-submit="create_set" id="create-set-form" class="flex gap-2">
            <input
              type="text"
              name="name"
              required
              placeholder="New set name"
              class="input input-bordered input-sm w-48"
            />
            <button class="btn btn-sm">Create set</button>
          </form>
          <label :if={@selected_set} class="flex items-center gap-1 text-sm" id="gate-toggle">
            <input
              type="checkbox"
              class="checkbox checkbox-xs"
              checked={@selected_set.gate}
              phx-click="toggle_gate"
            /> run on publish
          </label>
          <form :if={@selected_set} phx-submit="set_schedule" id="schedule-form" class="flex gap-1">
            <input
              type="text"
              name="schedule"
              value={@selected_set.schedule}
              placeholder="cron, e.g. 0 6 * * *"
              class="input input-bordered input-sm w-40 font-mono"
              title="Runs against the latest published version on this cron schedule; blank clears it."
            />
            <button class="btn btn-ghost btn-sm">Schedule</button>
          </form>
          <button
            :if={@selected_set}
            class="btn btn-ghost btn-sm text-error"
            phx-click="delete_set"
            phx-value-id={@selected_set.id}
            data-confirm="Delete this set and its cases?"
          >
            Delete set
          </button>
        </div>
      </div>

      <div :if={@selected_set} class="card border border-base-200 p-6 space-y-3" id="eval-cases-card">
        <h2 class="font-semibold">Cases — {@selected_set.name}</h2>

        <table :if={@cases != []} class="table table-xs">
          <thead>
            <tr>
              <th>Inputs</th>
              <th>Expected</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={eval_case <- @cases} id={"case-#{eval_case.id}"}>
              <td class="font-mono text-xs max-w-xs truncate">
                {Jason.encode!(eval_case.inputs)}
              </td>
              <td class="max-w-md truncate">{eval_case.expected}</td>
              <td>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_case"
                  phx-value-id={eval_case.id}
                >
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-submit="add_case" id="add-case-form" class="space-y-2">
          <div class="flex flex-wrap gap-2">
            <input
              :for={variable <- start_variables(@workflow)}
              type="text"
              name={"inputs[#{variable}]"}
              placeholder={variable}
              class="input input-bordered input-sm w-48"
            />
            <input
              type="text"
              name="expected"
              required
              placeholder="Expected answer / criteria"
              class="input input-bordered input-sm w-72"
            />
            <button class="btn btn-sm">Add case</button>
          </div>
        </form>

        <form
          :if={@recent_runs != []}
          phx-submit="add_case_from_run"
          id="add-case-from-run-form"
          class="flex items-center gap-2"
        >
          <select name="run_id" class="select select-bordered select-sm max-w-md">
            <option :for={run <- @recent_runs} value={run.id}>
              {Calendar.strftime(run.inserted_at, "%m-%d %H:%M")} · {run.inputs
              |> Jason.encode!()
              |> String.slice(0, 60)}
            </option>
          </select>
          <button class="btn btn-sm">Capture run as case</button>
        </form>

        <form
          phx-submit="import_cases"
          phx-change="validate_csv"
          id="import-cases-form"
          class="flex items-center gap-2"
        >
          <.live_file_input
            upload={@uploads.cases_csv}
            class="file-input file-input-bordered file-input-sm"
          />
          <button class="btn btn-sm">Import CSV</button>
          <span class="text-xs opacity-60">
            columns: {Enum.join(start_variables(@workflow) ++ ["expected"], ", ")}
          </span>
        </form>
      </div>

      <div :if={@selected_set} class="card border border-base-200 p-6 space-y-3" id="eval-runs-card">
        <div class="flex items-center gap-3">
          <h2 class="font-semibold">Evaluation runs</h2>
          <form phx-submit="run_eval" id="run-eval-form" class="flex items-center gap-2">
            <select name="target" class="select select-bordered select-sm">
              <option value="draft">draft</option>
              <option :for={version <- @versions} value={"v#{version.version}"}>
                v{version.version}
              </option>
            </select>
            <select name="grader" class="select select-bordered select-sm">
              <option value="llm_judge">LLM judge</option>
              <option value="contains">contains</option>
              <option value="exact">exact</option>
            </select>
            <select name="judge" class="select select-bordered select-sm">
              <option value="default">judge: workspace default</option>
              <option
                :for={%{plugin_id: plugin_id, model: model} <- @models}
                value={"#{plugin_id}|#{model.name}"}
              >
                judge: {model.label || model.name}
              </option>
            </select>
            <button class="btn btn-primary btn-sm">Run evaluation</button>
          </form>
        </div>

        <p :if={@eval_runs == []} class="text-sm opacity-60">
          No evaluation runs yet — run one and find out whether this is heavy.
        </p>

        <table :if={@eval_runs != []} class="table table-sm">
          <thead>
            <tr>
              <th>Started</th>
              <th>Target</th>
              <th>Grader</th>
              <th>Score</th>
              <th>Passed</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={eval_run <- @eval_runs} id={"eval-#{eval_run.id}"}>
              <td class="text-xs opacity-70">{eval_run.inserted_at}</td>
              <td><span class="badge badge-ghost badge-sm">{eval_run.target}</span></td>
              <td class="text-xs">{eval_run.grader}</td>
              <td class="font-mono">
                {(eval_run.avg_score && Float.round(eval_run.avg_score * 100, 1)) || "—"}<span
                  :if={eval_run.avg_score}
                  class="opacity-60"
                >%</span>
                <span
                  :if={delta = score_delta(eval_run, @eval_runs)}
                  class={[
                    "badge badge-xs ml-1",
                    (delta < 0 && "badge-error") || (delta > 0 && "badge-success") ||
                      "badge-ghost"
                  ]}
                >
                  {(delta >= 0 && "+") || ""}{delta}
                </span>
              </td>
              <td>
                <span class="text-success">{eval_run.passed}</span>
                <span class="opacity-60">/ {eval_run.total}</span>
                <span :if={eval_run.status == :running} class="badge badge-info badge-xs ml-1">
                  running
                </span>
              </td>
              <td>
                <button
                  :if={eval_run.status == :completed}
                  class="btn btn-ghost btn-xs"
                  phx-click="toggle_results"
                  phx-value-id={eval_run.id}
                >
                  {(@expanded_eval == eval_run.id && "Hide") || "Details"}
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <div :if={expanded_results(assigns)} class="space-y-1" id="eval-results-detail">
          <p class="text-sm font-semibold">Per-case results</p>
          <table class="table table-xs">
            <thead>
              <tr>
                <th>Inputs</th>
                <th>Output</th>
                <th>Score</th>
                <th>Reason</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={result <- expanded_results(assigns).results}>
                <td class="font-mono text-xs max-w-40 truncate">
                  {Jason.encode!(result["inputs"])}
                </td>
                <td class="max-w-60 truncate">{result["output"] || result["error"]}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    (result["verdict"] == "pass" && "badge-success") || "badge-error"
                  ]}>
                    {result["score"]}
                  </span>
                </td>
                <td class="text-xs opacity-70 max-w-60 truncate">{result["reason"]}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
