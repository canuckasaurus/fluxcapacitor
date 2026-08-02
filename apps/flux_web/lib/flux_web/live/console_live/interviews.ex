defmodule FluxWeb.ConsoleLive.Interviews do
  @moduledoc """
  The interview library: reusable question sets that interview nodes
  present as a form when a run pauses — docassemble-style input
  templates, authored once and plugged into any flux.
  """
  use FluxWeb, :live_view

  alias Flux.Interviews
  alias Flux.RBAC

  @blank_question %{
    "name" => "",
    "label" => "",
    "type" => "text",
    "required" => true,
    "help" => "",
    "options" => []
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: "Interviews",
       interviews: Interviews.list(scope),
       can_edit: RBAC.can?(scope, :app_edit),
       editing: nil,
       form_error: nil
     )}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket,
       editing: %{
         "id" => nil,
         "name" => "",
         "description" => "",
         "intro" => "",
         "questions" => [@blank_question]
       },
       form_error: nil
     )}
  end

  def handle_event("edit", %{"interview-id" => id}, socket) do
    case Interviews.get(socket.assigns.current_scope, id) do
      {:error, :not_found} ->
        {:noreply, socket}

      interview ->
        {:noreply,
         assign(socket,
           editing: %{
             "id" => interview.id,
             "name" => interview.name,
             "description" => interview.description || "",
             "intro" => interview.intro || "",
             "questions" => interview.questions
           },
           form_error: nil
         )}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form_error: nil)}
  end

  def handle_event("form_change", params, socket) do
    {:noreply, assign(socket, editing: editing_from_params(socket.assigns.editing, params))}
  end

  def handle_event("add_question", _params, socket) do
    editing =
      Map.update!(socket.assigns.editing, "questions", &(&1 ++ [@blank_question]))

    {:noreply, assign(socket, editing: editing)}
  end

  def handle_event("remove_question", %{"index" => index}, socket) do
    index = String.to_integer(index)
    editing = Map.update!(socket.assigns.editing, "questions", &List.delete_at(&1, index))
    {:noreply, assign(socket, editing: editing)}
  end

  def handle_event("move_question", %{"index" => index, "dir" => dir}, socket) do
    index = String.to_integer(index)
    offset = (dir == "up" && -1) || 1

    editing =
      Map.update!(socket.assigns.editing, "questions", fn questions ->
        target = index + offset

        if target < 0 or target >= length(questions) do
          questions
        else
          question = Enum.at(questions, index)
          questions |> List.delete_at(index) |> List.insert_at(target, question)
        end
      end)

    {:noreply, assign(socket, editing: editing)}
  end

  def handle_event("save", params, socket) do
    scope = socket.assigns.current_scope
    editing = editing_from_params(socket.assigns.editing, params)

    attrs = %{
      "name" => editing["name"],
      "description" => editing["description"],
      "intro" => editing["intro"],
      "questions" => editing["questions"]
    }

    result =
      case editing["id"] do
        nil ->
          Interviews.create(scope, attrs)

        id ->
          case Interviews.get(scope, id) do
            {:error, :not_found} -> {:error, :not_found}
            interview -> Interviews.update(scope, interview, attrs)
          end
      end

    case result do
      {:ok, interview} ->
        {:noreply,
         socket
         |> put_flash(:info, "\"#{interview.name}\" saved.")
         |> assign(interviews: Interviews.list(scope), editing: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, editing: editing, form_error: changeset_error(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit interviews.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That interview no longer exists.")}
    end
  end

  def handle_event("delete", %{"interview-id" => id}, socket) do
    scope = socket.assigns.current_scope
    Interviews.delete(scope, id)
    {:noreply, assign(socket, interviews: Interviews.list(scope), editing: nil)}
  end

  # The form posts q[<index>][field] rows; rebuild the ordered list.
  defp editing_from_params(editing, params) do
    questions =
      (params["q"] || %{})
      |> Enum.sort_by(fn {index, _fields} -> String.to_integer(index) end)
      |> Enum.map(fn {_index, fields} ->
        %{
          "name" => fields["name"] || "",
          "label" => fields["label"] || "",
          "type" => fields["type"] || "text",
          "required" => fields["required"] == "on" or fields["required"] == "true",
          "help" => fields["help"] || "",
          "options" => fields["options"] || ""
        }
      end)

    editing
    |> Map.put("name", params["name"] || editing["name"])
    |> Map.put("description", params["description"] || editing["description"])
    |> Map.put("intro", params["intro"] || editing["intro"])
    |> Map.put("questions", (questions == [] && editing["questions"]) || questions)
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  defp options_text(options) when is_list(options), do: Enum.join(options, ", ")
  defp options_text(options), do: to_string(options || "")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:interviews}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Interviews</h1>
          <p class="opacity-70 mt-1">
            Reusable question sets — an interview node pauses the run and asks them as one form.
          </p>
        </div>
        <button :if={@can_edit and @editing == nil} class="btn btn-primary" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> New interview
        </button>
      </div>

      <div :if={@editing} class="card border border-base-200 p-6 space-y-3">
        <form phx-submit="save" phx-change="form_change" id="interview-form" class="space-y-3">
          <div class="flex gap-2 flex-wrap">
            <input
              type="text"
              name="name"
              value={@editing["name"]}
              placeholder="Client intake"
              required
              class="input input-bordered input-sm w-64"
            />
            <input
              type="text"
              name="description"
              value={@editing["description"]}
              placeholder="Description (optional)"
              class="input input-bordered input-sm flex-1 min-w-48"
            />
          </div>
          <input
            type="text"
            name="intro"
            value={@editing["intro"]}
            placeholder="Intro shown above the form (optional, templated)"
            class="input input-bordered input-sm w-full"
          />

          <div class="space-y-2">
            <div
              :for={{question, index} <- Enum.with_index(@editing["questions"])}
              class="rounded-box border border-base-200 p-3 space-y-2"
              id={"question-#{index}"}
            >
              <div class="flex gap-2 flex-wrap items-center">
                <input
                  type="text"
                  name={"q[#{index}][name]"}
                  value={question["name"]}
                  placeholder="variable_name"
                  class="input input-bordered input-xs w-40 font-mono"
                />
                <input
                  type="text"
                  name={"q[#{index}][label]"}
                  value={question["label"]}
                  placeholder="Question label"
                  class="input input-bordered input-xs flex-1 min-w-40"
                />
                <select name={"q[#{index}][type]"} class="select select-xs w-28">
                  <option
                    :for={type <- Flux.Interviews.question_types()}
                    value={type}
                    selected={question["type"] == type}
                  >
                    {type}
                  </option>
                </select>
                <label class="label cursor-pointer gap-1 text-xs">
                  <input
                    type="checkbox"
                    name={"q[#{index}][required]"}
                    checked={question["required"]}
                    class="checkbox checkbox-xs"
                  /> required
                </label>
                <div class="ml-auto flex gap-1">
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="move_question"
                    phx-value-index={index}
                    phx-value-dir="up"
                    title="Move up"
                  >
                    <.icon name="hero-chevron-up" class="size-3" />
                  </button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="move_question"
                    phx-value-index={index}
                    phx-value-dir="down"
                    title="Move down"
                  >
                    <.icon name="hero-chevron-down" class="size-3" />
                  </button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="remove_question"
                    phx-value-index={index}
                    title="Remove question"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
              </div>
              <div class="flex gap-2 flex-wrap">
                <input
                  type="text"
                  name={"q[#{index}][help]"}
                  value={question["help"]}
                  placeholder="Help text (optional)"
                  class="input input-bordered input-xs flex-1 min-w-40"
                />
                <input
                  :if={question["type"] == "select"}
                  type="text"
                  name={"q[#{index}][options]"}
                  value={options_text(question["options"])}
                  placeholder="Options, comma separated"
                  class="input input-bordered input-xs w-64"
                />
              </div>
            </div>
          </div>

          <button type="button" class="btn btn-outline btn-xs" phx-click="add_question">
            <.icon name="hero-plus" class="size-3" /> Add question
          </button>

          <p :if={@form_error} class="text-sm text-error">{@form_error}</p>

          <div class="flex gap-2">
            <button class="btn btn-primary btn-sm">Save interview</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel">Cancel</button>
          </div>
        </form>
      </div>

      <Layouts.empty_state
        :if={@interviews == [] and @editing == nil}
        icon="hero-clipboard-document-check"
        title="No interviews yet"
      >
        <p>
          Define a question set here, then drop an interview node into a flux —
          the run pauses and asks these questions as one form.
        </p>
      </Layouts.empty_state>

      <div class="grid gap-4 sm:grid-cols-2">
        <div
          :for={interview <- @interviews}
          class="card border border-base-200 p-5 space-y-2"
          id={"interview-#{interview.id}"}
        >
          <div class="flex items-start justify-between">
            <h2 class="font-semibold">{interview.name}</h2>
            <div :if={@can_edit} class="flex gap-1">
              <button
                class="btn btn-ghost btn-xs"
                phx-click="edit"
                phx-value-interview-id={interview.id}
              >
                Edit
              </button>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="delete"
                phx-value-interview-id={interview.id}
                data-confirm={"Delete #{interview.name}? Nodes using it will fail until rebound."}
              >
                Delete
              </button>
            </div>
          </div>
          <p :if={interview.description} class="text-sm opacity-70">{interview.description}</p>
          <ol class="text-xs space-y-1 opacity-80 list-decimal list-inside">
            <li :for={question <- interview.questions}>
              {question["label"]}
              <span class="font-mono opacity-60">({question["name"]}, {question["type"]})</span>
              <span :if={question["required"]} class="text-error">*</span>
            </li>
          </ol>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
