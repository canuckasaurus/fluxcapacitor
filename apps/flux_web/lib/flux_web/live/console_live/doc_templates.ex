defmodule FluxWeb.ConsoleLive.DocTemplates do
  @moduledoc """
  The doc template library: user-provided Jinja documents that template
  nodes plug into. Editing shows a live preview rendered against a
  sample JSON context, so template authors see exactly what a run would
  produce.
  """
  use FluxWeb, :live_view

  alias Flux.DocTemplates
  alias Flux.RBAC

  @sample_context ~s({\n  "start": {"query": "example question"},\n  "llm_1": {"text": "example answer"}\n})

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: "Doc templates",
       templates: DocTemplates.list(scope),
       can_edit: RBAC.can?(scope, :app_edit),
       editing: nil,
       form_error: nil,
       preview: nil,
       preview_context: @sample_context
     )}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket,
       editing: %{"id" => nil, "name" => "", "description" => "", "content" => ""},
       form_error: nil,
       preview: nil
     )}
  end

  def handle_event("edit", %{"template-id" => id}, socket) do
    case DocTemplates.get(socket.assigns.current_scope, id) do
      {:error, :not_found} ->
        {:noreply, socket}

      template ->
        {:noreply,
         socket
         |> assign(
           editing: %{
             "id" => template.id,
             "name" => template.name,
             "description" => template.description || "",
             "content" => template.content
           },
           form_error: nil
         )
         |> run_preview(template.content, socket.assigns.preview_context)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form_error: nil, preview: nil)}
  end

  # Live preview: every keystroke re-renders content against the sample
  # context (both are in the same form).
  def handle_event("preview", params, socket) do
    editing =
      socket.assigns.editing
      |> Map.put("name", params["name"] || "")
      |> Map.put("description", params["description"] || "")
      |> Map.put("content", params["content"] || "")

    {:noreply,
     socket
     |> assign(editing: editing, preview_context: params["context"] || @sample_context)
     |> run_preview(editing["content"], params["context"] || @sample_context)}
  end

  def handle_event("save", params, socket) do
    scope = socket.assigns.current_scope

    attrs = %{
      "name" => params["name"],
      "description" => params["description"],
      "content" => params["content"]
    }

    result =
      case socket.assigns.editing["id"] do
        nil ->
          DocTemplates.create(scope, attrs)

        id ->
          case DocTemplates.get(scope, id) do
            {:error, :not_found} -> {:error, :not_found}
            template -> DocTemplates.update(scope, template, attrs)
          end
      end

    case result do
      {:ok, template} ->
        {:noreply,
         socket
         |> put_flash(:info, "\"#{template.name}\" saved.")
         |> assign(templates: DocTemplates.list(scope), editing: nil, preview: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form_error: changeset_error(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit templates.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That template no longer exists.")}
    end
  end

  def handle_event("delete", %{"template-id" => id}, socket) do
    scope = socket.assigns.current_scope
    DocTemplates.delete(scope, id)

    {:noreply, assign(socket, templates: DocTemplates.list(scope), editing: nil, preview: nil)}
  end

  defp run_preview(socket, content, context_json) do
    context =
      case Jason.decode(context_json || "") do
        {:ok, %{} = context} -> context
        _invalid -> %{}
      end

    preview =
      case Flux.Engine.Jinja.render(content || "", context) do
        {:ok, output} -> {:ok, output}
        {:error, message} -> {:error, message}
      end

    assign(socket, preview: preview)
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:templates}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Doc templates</h1>
          <p class="opacity-70 mt-1">
            Reusable Jinja documents — template nodes plug them in by name.
          </p>
        </div>
        <button :if={@can_edit and @editing == nil} class="btn btn-primary" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> New template
        </button>
      </div>

      <div :if={@editing} class="card border border-base-200 p-6 space-y-3">
        <form phx-submit="save" phx-change="preview" id="doc-template-form" class="space-y-3">
          <div class="flex gap-2 flex-wrap">
            <input
              type="text"
              name="name"
              value={@editing["name"]}
              placeholder="Offer letter"
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

          <div class="grid gap-3 lg:grid-cols-2">
            <label class="form-control">
              <span class="label-text text-xs opacity-70 mb-1">
                Template (Jinja: {"{{ vars | filters }}"}, {"{% if %}"}, {"{% for %}"})
              </span>
              <textarea
                name="content"
                rows="14"
                class="textarea textarea-bordered font-mono text-xs w-full"
                placeholder="Dear {{ start.name | capitalize }},\n\n{% if start.approved %}Welcome aboard!{% else %}Thanks for applying.{% endif %}"
              >{@editing["content"]}</textarea>
            </label>
            <div class="space-y-2">
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">
                  Preview context (JSON — stands in for the run's variables)
                </span>
                <textarea
                  name="context"
                  rows="5"
                  class="textarea textarea-bordered font-mono text-xs w-full"
                >{@preview_context}</textarea>
              </label>
              <div class="rounded-box border border-base-200 p-3 min-h-24">
                <p class="text-xs font-semibold opacity-70 mb-1">Preview</p>
                <p :if={@preview == nil} class="text-xs opacity-50">Start typing to preview.</p>
                <pre
                  :if={match?({:ok, _}, @preview)}
                  class="text-xs whitespace-pre-wrap"
                  id="template-preview"
                >{elem(@preview, 1)}</pre>
                <p :if={match?({:error, _}, @preview)} class="text-xs text-error">
                  {elem(@preview, 1)}
                </p>
              </div>
            </div>
          </div>

          <p :if={@form_error} class="text-sm text-error">{@form_error}</p>

          <div class="flex gap-2">
            <button class="btn btn-primary btn-sm">Save template</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel">Cancel</button>
          </div>
        </form>
      </div>

      <p :if={@templates == [] and @editing == nil} class="text-sm opacity-60">
        No templates yet — create one and select it from any template node.
      </p>

      <div class="grid gap-4 sm:grid-cols-2">
        <div
          :for={template <- @templates}
          class="card border border-base-200 p-5 space-y-2"
          id={"doc-template-#{template.id}"}
        >
          <div class="flex items-start justify-between">
            <h2 class="font-semibold">{template.name}</h2>
            <div :if={@can_edit} class="flex gap-1">
              <button
                class="btn btn-ghost btn-xs"
                phx-click="edit"
                phx-value-template-id={template.id}
              >
                Edit
              </button>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="delete"
                phx-value-template-id={template.id}
                data-confirm={"Delete #{template.name}? Nodes using it will fail until rebound."}
              >
                Delete
              </button>
            </div>
          </div>
          <p :if={template.description} class="text-sm opacity-70">{template.description}</p>
          <pre class="rounded bg-base-200 p-2 text-xs overflow-hidden max-h-20">{String.slice(template.content, 0, 240)}</pre>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
