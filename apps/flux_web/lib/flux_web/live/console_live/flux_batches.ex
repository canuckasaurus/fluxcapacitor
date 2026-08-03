defmodule FluxWeb.ConsoleLive.FluxBatches do
  @moduledoc """
  Batch runs: upload a CSV whose header row names the flux's start
  variables, run the draft once per row, watch counters live, download
  the results as CSV.
  """
  use FluxWeb, :live_view

  alias Flux.Workflows
  alias Flux.Workflows.Workflow

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow(scope, id) do
      %Workflow{} = workflow ->
        if connected?(socket), do: Workflows.subscribe_batches(workflow.id)

        {:ok,
         socket
         |> assign(
           page_title: "Batch runs — #{workflow.name}",
           workflow: workflow,
           versions: Workflows.list_versions(scope, workflow.id),
           batches: Workflows.list_batches(scope, workflow.id),
           schedules: Workflows.list_batch_schedules(scope, workflow.id),
           labeling_projects: Flux.Labeling.list_projects(scope),
           selected_labeling_project:
             scope |> Flux.Labeling.list_projects() |> List.first() |> then(&(&1 && &1.id))
         )
         |> allow_upload(:csv, accept: ~w(.csv .txt), max_entries: 1, max_file_size: 2_000_000)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Flux not found.")
         |> push_navigate(to: ~p"/console/fluxes")}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("run_batch", params, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow

    version =
      case params["target"] do
        "v" <> number -> String.to_integer(number)
        _draft -> nil
      end

    uploads =
      consume_uploaded_entries(socket, :csv, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    with [{filename, text}] <- uploads,
         {:ok, rows} <- Flux.CSV.parse_with_header(text),
         {:ok, _batch} <-
           Workflows.start_batch(scope, workflow, rows, name: filename, version: version) do
      {:noreply,
       socket
       |> put_flash(:info, "Batch started — #{length(rows)} rows.")
       |> assign(batches: Workflows.list_batches(scope, workflow.id))}
    else
      [] ->
        {:noreply, put_flash(socket, :error, "Choose a CSV file first.")}

      {:error, :empty} ->
        {:noreply, put_flash(socket, :error, "That CSV has no data rows.")}

      {:error, :invalid_header} ->
        {:noreply,
         put_flash(socket, :error, "The first row must name the start variables (no blanks).")}

      {:error, {:too_many_rows, max}} ->
        {:noreply, put_flash(socket, :error, "Batches cap at #{max} rows — split the file.")}

      {:error, {:invalid_graph, [error | _rest]}} ->
        {:noreply, put_flash(socket, :error, "The target graph is invalid: #{error}")}

      {:error, :version_not_found} ->
        {:noreply, put_flash(socket, :error, "That published version no longer exists.")}
    end
  end

  def handle_event("schedule_batch", %{"batch-id" => batch_id, "cron" => cron}, socket) do
    scope = socket.assigns.current_scope

    case Workflows.schedule_batch(scope, batch_id, cron) do
      {:ok, schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Scheduled — \"#{schedule.name}\" re-runs at `#{schedule.cron}`.")
         |> assign(schedules: Workflows.list_batch_schedules(scope, socket.assigns.workflow.id))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "That isn't a valid cron expression.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not schedule the batch.")}
    end
  end

  def handle_event("toggle_schedule", %{"schedule-id" => schedule_id}, socket) do
    scope = socket.assigns.current_scope
    Workflows.toggle_batch_schedule(scope, schedule_id)

    {:noreply,
     assign(socket, schedules: Workflows.list_batch_schedules(scope, socket.assigns.workflow.id))}
  end

  def handle_event("delete_schedule", %{"schedule-id" => schedule_id}, socket) do
    scope = socket.assigns.current_scope
    Workflows.delete_batch_schedule(scope, schedule_id)

    {:noreply,
     assign(socket, schedules: Workflows.list_batch_schedules(scope, socket.assigns.workflow.id))}
  end

  def handle_event("select_labeling_project", %{"project_id" => project_id}, socket) do
    {:noreply, assign(socket, selected_labeling_project: project_id)}
  end

  def handle_event("send_batch_to_labeling", %{"batch-id" => batch_id}, socket) do
    scope = socket.assigns.current_scope

    with project_id when is_binary(project_id) <- socket.assigns.selected_labeling_project,
         %Flux.Labeling.Project{} = project <- Flux.Labeling.get_project(scope, project_id),
         {:ok, tasks} <- Flux.Labeling.add_tasks_from_batch(scope, project, batch_id) do
      {:noreply, put_flash(socket, :info, "#{length(tasks)} results queued in #{project.name}.")}
    else
      {:error, :no_succeeded_runs} ->
        {:noreply, put_flash(socket, :error, "That batch has no succeeded rows to label.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not queue the batch for labeling.")}
    end
  end

  @impl true
  def handle_info({:batch_updated, _batch_id}, socket) do
    {:noreply,
     assign(
       socket,
       batches: Workflows.list_batches(socket.assigns.current_scope, socket.assigns.workflow.id)
     )}
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
        <h1 class="text-2xl font-bold">{gettext("Batch runs")}</h1>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="batch-upload-card">
        <h2 class="font-semibold">Run the draft over a CSV</h2>
        <p class="text-sm opacity-70">
          The header row names the start variables
          <span :if={start_variables(@workflow) != []}>
            (this flux expects <span class="font-mono">{Enum.join(start_variables(@workflow), ", ")}</span>)
          </span>
          — each data row becomes one run.
        </p>

        <form
          phx-submit="run_batch"
          phx-change="validate"
          id="batch-upload-form"
          class="flex items-center gap-2"
        >
          <.live_file_input
            upload={@uploads.csv}
            class="file-input file-input-bordered file-input-sm"
          />
          <select name="target" class="select select-bordered select-sm">
            <option value="draft">draft</option>
            <option :for={version <- @versions} value={"v#{version.version}"}>
              v{version.version}
            </option>
          </select>
          <button class="btn btn-primary btn-sm">Run batch</button>
        </form>
        <p :for={err <- upload_errors(@uploads.csv)} class="text-sm text-error">
          {inspect(err)}
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="batch-list-card">
        <div class="flex items-center gap-3">
          <h2 class="font-semibold">Batches</h2>
          <form
            :if={@labeling_projects != []}
            phx-change="select_labeling_project"
            id="labeling-project-form"
            class="ml-auto flex items-center gap-2 text-xs"
          >
            <span class="opacity-60">labeling target:</span>
            <select name="project_id" class="select select-bordered select-xs">
              <option
                :for={project <- @labeling_projects}
                value={project.id}
                selected={@selected_labeling_project == project.id}
              >
                {project.name}
              </option>
            </select>
          </form>
        </div>
        <p :if={@batches == []} class="text-sm opacity-60">
          No batches yet — upload a CSV above. Where we're going, we don't
          need roads; rows, however, are required.
        </p>
        <table :if={@batches != []} class="table table-sm">
          <thead>
            <tr>
              <th>File</th>
              <th>Started</th>
              <th>Progress</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={batch <- @batches} id={"batch-#{batch.id}"}>
              <td>
                {batch.name}
                <span class="badge badge-ghost badge-xs ml-1">{batch.target}</span>
              </td>
              <td class="text-xs opacity-70">{batch.inserted_at}</td>
              <td>
                <span class="text-success">{batch.succeeded} ok</span>
                <span :if={batch.failed > 0} class="text-error">· {batch.failed} failed</span>
                <span class="opacity-60">/ {batch.total}</span>
              </td>
              <td>
                <span class={[
                  "badge badge-sm",
                  (batch.status == :completed && "badge-success") || "badge-info"
                ]}>
                  {batch.status}
                </span>
              </td>
              <td class="flex gap-1">
                <a
                  href={~p"/console/fluxes/#{@workflow.id}/batches/#{batch.id}/results"}
                  class="btn btn-ghost btn-xs"
                >
                  Results CSV
                </a>
                <button
                  :if={batch.status == :completed and @selected_labeling_project}
                  class="btn btn-ghost btn-xs"
                  phx-click="send_batch_to_labeling"
                  phx-value-batch-id={batch.id}
                >
                  To labeling
                </button>
                <form
                  :if={batch.status == :completed}
                  phx-submit="schedule_batch"
                  class="inline-flex gap-1"
                >
                  <input type="hidden" name="batch-id" value={batch.id} />
                  <input
                    type="text"
                    name="cron"
                    placeholder="0 6 * * *"
                    class="input input-xs w-24 font-mono"
                    title="Cron expression — saves this batch's rows as a recurring schedule"
                  />
                  <button class="btn btn-ghost btn-xs">Repeat</button>
                </form>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@schedules != []}
        class="card border border-base-200 p-6 space-y-3"
        id="batch-schedules-card"
      >
        <h2 class="font-semibold">Recurring batches</h2>
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Name</th>
              <th>Cron</th>
              <th>Target</th>
              <th>Rows</th>
              <th>Last run</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={schedule <- @schedules} id={"schedule-#{schedule.id}"}>
              <td>{schedule.name}</td>
              <td class="font-mono text-xs">{schedule.cron}</td>
              <td><span class="badge badge-ghost badge-xs">{schedule.target}</span></td>
              <td class="text-xs">{length(schedule.rows)}</td>
              <td class="text-xs opacity-70">
                {(schedule.last_run_at && Calendar.strftime(schedule.last_run_at, "%m-%d %H:%M")) ||
                  "never"}
              </td>
              <td class="whitespace-nowrap">
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="toggle_schedule"
                  phx-value-schedule-id={schedule.id}
                >
                  {(schedule.enabled && "Pause") || "Resume"}
                </button>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_schedule"
                  phx-value-schedule-id={schedule.id}
                  data-confirm="Delete this recurring batch?"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
