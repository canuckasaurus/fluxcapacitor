defmodule FluxWeb.ConsoleLive.Labeling do
  @moduledoc """
  The data tagging GUI: pick a project, work the unlabeled queue one
  task at a time (choice buttons / multi checkboxes / free-text), skip
  what's ambiguous, relabel anything from the labeled list, and export
  the labeled set as JSONL for a training code node.
  """
  use FluxWeb, :live_view

  alias Flux.Labeling

  @impl true
  def mount(_params, _session, socket) do
    projects = Labeling.list_projects(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       page_title: "Labeling",
       projects: projects,
       selected_project: List.first(projects),
       current_task: nil
     )
     |> assign_queue()
     |> allow_upload(:tasks_csv,
       accept: ~w(.csv .txt),
       max_entries: 1,
       max_file_size: 1_000_000
     )}
  end

  defp assign_queue(socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.selected_project do
      nil ->
        assign(socket,
          current_task: nil,
          counts: nil,
          labeled: [],
          labeler_stats: [],
          agreement: nil
        )

      project ->
        assign(socket,
          current_task: socket.assigns[:current_task] || Labeling.next_task(scope, project.id),
          counts: Labeling.counts(scope, project.id),
          labeled: Labeling.list_labeled(scope, project.id),
          labeler_stats: Labeling.labeler_stats(scope, project.id),
          agreement: Labeling.agreement_stats(scope, project.id)
        )
    end
  end

  defp advance(socket) do
    socket |> assign(current_task: nil) |> assign_queue()
  end

  defp reload_projects(socket, keep_id \\ nil) do
    projects = Labeling.list_projects(socket.assigns.current_scope)
    selected = Enum.find(projects, List.first(projects), &(&1.id == keep_id))

    socket
    |> assign(projects: projects, selected_project: selected, current_task: nil)
    |> assign_queue()
  end

  @impl true
  def handle_event("create_project", params, socket) do
    attrs = %{
      "name" => params["name"],
      "label_type" => params["label_type"],
      "options" => String.split(to_string(params["options"] || ""), ","),
      "instructions" => params["instructions"],
      "required_labels" => params["required_labels"] || "1"
    }

    case Labeling.create_project(socket.assigns.current_scope, attrs) do
      {:ok, project} ->
        {:noreply, socket |> put_flash(:info, "Project created.") |> reload_projects(project.id)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage labeling.")}

      {:error, changeset} ->
        {field, {message, _meta}} = List.first(changeset.errors)
        {:noreply, put_flash(socket, :error, "#{field} #{message}")}
    end
  end

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply, reload_projects(socket, id)}
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    case Labeling.delete_project(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Project deleted.") |> reload_projects()}
      _error -> {:noreply, put_flash(socket, :error, "Could not delete the project.")}
    end
  end

  def handle_event("label_choice", %{"task-id" => task_id, "choice" => choice}, socket) do
    apply_label(socket, task_id, %{"choice" => choice})
  end

  # Keyboard tagging (1-9 pick a choice, s skips) — only wired for
  # single-choice projects, where no text field competes for keystrokes.
  def handle_event("queue_shortcut", %{"key" => key}, socket) do
    with %{} = task <- socket.assigns.current_task,
         %{label_type: :choice, options: options} <- socket.assigns.selected_project do
      cond do
        key in ~w(s S) ->
          {:noreply, elem(handle_event("skip_task", %{"task-id" => task.id}, socket), 1)}

        key =~ ~r/^[1-9]$/ and String.to_integer(key) <= length(options) ->
          choice = Enum.at(options, String.to_integer(key) - 1)
          apply_label(socket, task.id, %{"choice" => choice})

        true ->
          {:noreply, socket}
      end
    else
      _no_task_or_not_choice -> {:noreply, socket}
    end
  end

  def handle_event("label_multi", %{"task-id" => task_id} = params, socket) do
    apply_label(socket, task_id, %{"choices" => List.wrap(params["choices"])})
  end

  def handle_event("label_text", %{"task-id" => task_id, "text" => text}, socket) do
    apply_label(socket, task_id, %{"text" => text})
  end

  def handle_event("skip_task", %{"task-id" => task_id}, socket) do
    case Labeling.skip_task(socket.assigns.current_scope, task_id) do
      {:ok, _} -> {:noreply, advance(socket)}
      _error -> {:noreply, put_flash(socket, :error, "Could not skip the task.")}
    end
  end

  def handle_event("relabel", %{"task-id" => task_id}, socket) do
    case Labeling.get_task(socket.assigns.current_scope, task_id) do
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Task not found.")}
      task -> {:noreply, assign(socket, current_task: task)}
    end
  end

  def handle_event("delete_task", %{"task-id" => task_id}, socket) do
    case Labeling.delete_task(socket.assigns.current_scope, task_id) do
      {:ok, _} -> {:noreply, advance(socket)}
      _error -> {:noreply, put_flash(socket, :error, "Could not delete the task.")}
    end
  end

  def handle_event("validate_csv", _params, socket), do: {:noreply, socket}

  def handle_event("import_tasks", _params, socket) do
    uploads =
      consume_uploaded_entries(socket, :tasks_csv, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    with [text] <- uploads,
         {:ok, rows} <- Flux.CSV.parse_with_header(text),
         {:ok, tasks} <-
           Labeling.add_tasks_from_rows(
             socket.assigns.current_scope,
             socket.assigns.selected_project,
             rows
           ) do
      {:noreply, socket |> put_flash(:info, "Imported #{length(tasks)} tasks.") |> advance()}
    else
      [] ->
        {:noreply, put_flash(socket, :error, "Choose a CSV file first.")}

      {:error, {:too_many_tasks, max}} ->
        {:noreply, put_flash(socket, :error, "Imports cap at #{max} tasks — split the file.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That CSV could not be parsed.")}
    end
  end

  defp apply_label(socket, task_id, label) do
    case Labeling.label_task(socket.assigns.current_scope, task_id, label) do
      {:ok, _task} ->
        {:noreply, advance(socket)}

      {:error, :invalid_label} ->
        {:noreply, put_flash(socket, :error, "Pick a valid label first.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the label.")}
    end
  end

  defp summarize_label(%{"choice" => choice}), do: choice
  defp summarize_label(%{"choices" => choices}), do: Enum.join(choices, ", ")
  defp summarize_label(%{"text" => text}), do: text
  defp summarize_label(_label), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:labeling}
    >
      <div>
        <h1 class="text-2xl font-bold">Labeling</h1>
        <p class="opacity-70 mt-1">
          Tag data for evals and custom models — labeled sets export as
          JSONL straight into a training code node.
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="labeling-projects-card">
        <h2 class="font-semibold">Projects</h2>
        <div class="flex flex-wrap items-center gap-2">
          <button
            :for={project <- @projects}
            class={[
              "btn btn-sm",
              (@selected_project && @selected_project.id == project.id && "btn-primary") ||
                "btn-ghost"
            ]}
            phx-click="select_project"
            phx-value-id={project.id}
          >
            {project.name}
          </button>
          <button
            :if={@selected_project}
            class="btn btn-ghost btn-sm text-error"
            phx-click="delete_project"
            phx-value-id={@selected_project.id}
            data-confirm="Delete this project and its tasks?"
          >
            Delete project
          </button>
        </div>

        <form phx-submit="create_project" id="create-project-form" class="flex flex-wrap gap-2">
          <input
            type="text"
            name="name"
            required
            placeholder="New project name"
            class="input input-bordered input-sm w-44"
          />
          <select name="label_type" class="select select-bordered select-sm">
            <option value="choice">single choice</option>
            <option value="multi">multi choice</option>
            <option value="text">free text</option>
          </select>
          <input
            type="text"
            name="options"
            placeholder="options, comma-separated (choice types)"
            class="input input-bordered input-sm w-72"
          />
          <input
            type="text"
            name="instructions"
            placeholder="labeler instructions — optional"
            class="input input-bordered input-sm w-72"
          />
          <label class="input input-bordered input-sm flex items-center gap-1 w-40">
            <span class="text-xs opacity-60">labelers/task</span>
            <input type="number" name="required_labels" value="1" min="1" max="5" class="grow" />
          </label>
          <button class="btn btn-primary btn-sm">Create project</button>
        </form>
      </div>

      <div
        :if={@selected_project}
        class="card border border-base-200 p-6 space-y-4"
        id="labeling-queue-card"
        phx-hook=".LabelShortcuts"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".LabelShortcuts">
          export default {
            mounted() {
              this.handler = (e) => {
                if (e.target.matches("input, textarea, select")) return
                if (e.metaKey || e.ctrlKey || e.altKey) return
                this.pushEvent("queue_shortcut", {key: e.key})
              }
              window.addEventListener("keydown", this.handler)
            },
            destroyed() { window.removeEventListener("keydown", this.handler) }
          }
        </script>
        <div class="flex items-center gap-3 flex-wrap">
          <h2 class="font-semibold">Queue — {@selected_project.name}</h2>
          <span :if={@counts} class="text-xs opacity-60">
            {@counts.labeled} labeled · {@counts.unlabeled} to go · {@counts.skipped} skipped
          </span>
          <span
            :for={{email, count} <- @labeler_stats}
            class="badge badge-ghost badge-sm"
            title="labeled by"
          >
            {email}: {count}
          </span>
          <span
            :if={@selected_project.required_labels > 1}
            class="badge badge-info badge-sm"
            title="labels required per task"
          >
            {@selected_project.required_labels} labelers/task
          </span>
          <span
            :if={@agreement}
            class="badge badge-ghost badge-sm"
            title="average share of votes matching the final label"
          >
            agreement {round(@agreement.avg_agreement * 100)}% · {@agreement.unanimous}/{@agreement.tasks} unanimous
          </span>
          <a
            :if={@counts && @counts.labeled > 0}
            href={~p"/console/labeling/#{@selected_project.id}/export"}
            class="btn btn-ghost btn-xs ml-auto"
          >
            Export JSONL
          </a>
        </div>

        <p :if={@selected_project.instructions} class="text-sm opacity-70">
          {@selected_project.instructions}
        </p>

        <p :if={@current_task == nil} class="text-sm opacity-60">
          Queue clear — nothing unlabeled. Great Scott, you're done (until
          the next batch lands).
        </p>

        <div :if={@current_task} class="space-y-3" id={"task-#{@current_task.id}"}>
          <div class="rounded-box bg-base-200 p-4 space-y-2">
            <div :for={{key, value} <- Enum.sort(@current_task.data)} class="text-sm">
              <span class="font-semibold opacity-70">{key}:</span>
              <span class="whitespace-pre-wrap break-words">{to_string(value)}</span>
            </div>
          </div>

          <div :if={@current_task.status == :labeled} class="text-xs opacity-60">
            Currently labeled: <span class="font-mono">{summarize_label(@current_task.label)}</span>
            — pick again to relabel.
          </div>

          <div :if={@selected_project.label_type == :choice} class="flex flex-wrap gap-2">
            <button
              :for={{option, index} <- Enum.with_index(@selected_project.options, 1)}
              class="btn btn-outline btn-sm"
              phx-click="label_choice"
              phx-value-task-id={@current_task.id}
              phx-value-choice={option}
            >
              <kbd :if={index <= 9} class="kbd kbd-xs">{index}</kbd> {option}
            </button>
            <span class="text-xs opacity-50 self-center">
              keys 1–{min(length(@selected_project.options), 9)} label · s skips
            </span>
          </div>

          <form
            :if={@selected_project.label_type == :multi}
            phx-submit="label_multi"
            id="multi-label-form"
            class="space-y-2"
          >
            <input type="hidden" name="task-id" value={@current_task.id} />
            <div class="flex flex-wrap gap-3">
              <label
                :for={option <- @selected_project.options}
                class="flex items-center gap-1 text-sm"
              >
                <input type="checkbox" name="choices[]" value={option} class="checkbox checkbox-xs" />
                {option}
              </label>
            </div>
            <button class="btn btn-primary btn-sm">Save label</button>
          </form>

          <form
            :if={@selected_project.label_type == :text}
            phx-submit="label_text"
            id="text-label-form"
            class="space-y-2"
          >
            <input type="hidden" name="task-id" value={@current_task.id} />
            <textarea
              name="text"
              rows="3"
              required
              placeholder="The correct answer / corrected text"
              class="textarea textarea-bordered w-full text-sm"
            >{(@current_task.label && @current_task.label["text"]) || @current_task.data["answer"]}</textarea>
            <button class="btn btn-primary btn-sm">Save label</button>
          </form>

          <div class="flex gap-2">
            <button
              class="btn btn-ghost btn-xs"
              phx-click="skip_task"
              phx-value-task-id={@current_task.id}
            >
              Skip
            </button>
            <button
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete_task"
              phx-value-task-id={@current_task.id}
            >
              Delete
            </button>
          </div>
        </div>

        <form
          phx-submit="import_tasks"
          phx-change="validate_csv"
          id="import-tasks-form"
          class="flex items-center gap-2"
        >
          <.live_file_input
            upload={@uploads.tasks_csv}
            class="file-input file-input-bordered file-input-sm"
          />
          <button class="btn btn-sm">Import CSV</button>
          <span class="text-xs opacity-60">each row becomes one task</span>
        </form>
      </div>

      <div
        :if={@selected_project && @labeled != []}
        class="card border border-base-200 p-6 space-y-3"
        id="labeled-list-card"
      >
        <h2 class="font-semibold">Recently labeled</h2>
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Data</th>
              <th>Label</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={task <- @labeled} id={"labeled-#{task.id}"}>
              <td class="font-mono text-xs max-w-md truncate">{Jason.encode!(task.data)}</td>
              <td class="max-w-xs truncate">{summarize_label(task.label)}</td>
              <td>
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="relabel"
                  phx-value-task-id={task.id}
                >
                  Relabel
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
