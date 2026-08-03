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
     socket
     |> assign(
       page_title: "Doc templates",
       templates: DocTemplates.list(scope),
       usages: DocTemplates.usage_map(scope),
       can_edit: RBAC.can?(scope, :app_edit),
       editing: nil,
       uploading: false,
       upload_parent: nil,
       upload_error: nil,
       form_error: nil,
       preview: nil,
       preview_context: @sample_context
     )
     |> allow_upload(:docx, accept: ~w(.docx), max_entries: 1, max_file_size: 10_000_000)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket,
       editing: %{"fork_of" => nil, "name" => "", "description" => "", "content" => ""},
       form_error: nil,
       preview: nil
     )}
  end

  # Templates are canonical: "fork" prefills the editor from the parent
  # and saving always creates a new template with lineage.
  def handle_event("fork", %{"template-id" => id}, socket) do
    case DocTemplates.get(socket.assigns.current_scope, id) do
      {:error, :not_found} ->
        {:noreply, socket}

      %{kind: "docx"} = template ->
        {:noreply,
         assign(socket,
           uploading: true,
           upload_parent: template,
           upload_error: nil,
           editing: nil
         )}

      template ->
        {:noreply,
         socket
         |> assign(
           editing: %{
             "fork_of" => template.id,
             "name" => template.name <> " (fork)",
             "description" => template.description || "",
             "content" => template.content
           },
           form_error: nil
         )
         |> run_preview(template.content, socket.assigns.preview_context)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     assign(socket,
       editing: nil,
       uploading: false,
       upload_parent: nil,
       upload_error: nil,
       form_error: nil,
       preview: nil
     )}
  end

  def handle_event("uploading", _params, socket) do
    {:noreply,
     assign(socket, uploading: true, upload_parent: nil, editing: nil, upload_error: nil)}
  end

  def handle_event("validate_docx", _params, socket), do: {:noreply, socket}

  def handle_event("save_docx", params, socket) do
    scope = socket.assigns.current_scope

    binaries =
      consume_uploaded_entries(socket, :docx, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    parent = socket.assigns.upload_parent

    result =
      case {parent, binaries} do
        {nil, [binary]} ->
          {:run,
           DocTemplates.create_docx(scope, %{
             binary: binary,
             name: params["name"],
             description: params["description"]
           })}

        {nil, []} ->
          :no_file

        {parent, list} ->
          {:run,
           DocTemplates.fork_docx(scope, parent, %{
             binary: List.first(list),
             name: params["name"],
             description: params["description"]
           })}
      end

    case result do
      :no_file ->
        {:noreply, assign(socket, upload_error: "Choose a .docx file first.")}

      {:run, outcome} ->
        case outcome do
          {:ok, template} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Saved — #{length(template.variables)} variable(s) found."
             )
             |> assign(
               templates: DocTemplates.list(scope),
               uploading: false,
               upload_parent: nil,
               upload_error: nil
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, upload_error: changeset_error(changeset))}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You don't have permission to edit templates.")}

          {:error, message} when is_binary(message) ->
            {:noreply, assign(socket, upload_error: message)}
        end
    end
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
      case socket.assigns.editing["fork_of"] do
        nil ->
          DocTemplates.create(scope, attrs)

        parent_id ->
          case DocTemplates.get(scope, parent_id) do
            {:error, :not_found} -> {:error, :not_found}
            parent -> DocTemplates.fork(scope, parent, attrs)
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

  def handle_event("scaffold", %{"template-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with template when not is_tuple(template) <- DocTemplates.get(scope, id),
         {:ok, workflow} <- DocTemplates.create_interview_flux(scope, template) do
      {:noreply,
       socket
       |> put_flash(:info, "Interview flux created — publish it to take answers.")
       |> push_navigate(to: ~p"/console/fluxes/#{workflow.id}")}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Could not scaffold from that template.")}
    end
  end

  def handle_event("delete", %{"template-id" => id}, socket) do
    scope = socket.assigns.current_scope
    DocTemplates.delete(scope, id)

    {:noreply,
     assign(socket,
       templates: DocTemplates.list(scope),
       usages: DocTemplates.usage_map(scope),
       editing: nil,
       preview: nil
     )}
  end

  def handle_event("adopt", %{"template-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with template when not is_tuple(template) <- DocTemplates.get(scope, id),
         parent_id when parent_id != nil <- template.parent_id,
         {:ok, touched} <- DocTemplates.rebind(scope, parent_id, template) do
      nodes = touched |> Enum.map(& &1.nodes) |> Enum.sum()

      {:noreply,
       socket
       |> put_flash(
         :info,
         "Rebound #{nodes} node(s) in #{length(touched)} flux(es) — republish them to go live."
       )
       |> assign(usages: DocTemplates.usage_map(scope))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not adopt that fork.")}
    end
  end

  defp usage_count(entries), do: entries |> Enum.map(&length(&1.nodes)) |> Enum.sum()

  defp parent_name(templates, parent_id) do
    case Enum.find(templates, &(&1.id == parent_id)) do
      nil -> "a deleted template"
      parent -> parent.name
    end
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
          <h1 class="text-2xl font-bold">{gettext("Doc templates")}</h1>

          <p class="opacity-70 mt-1">
            Reusable Jinja documents — template nodes plug them in by name.
          </p>
        </div>

        <div class="flex gap-2">
          <button
            :if={@can_edit and not @uploading}
            class="btn btn-outline"
            phx-click="uploading"
            title="Upload a Word document with Jinja tags; a document node fills it"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Upload .docx
          </button>
          <button :if={@can_edit and @editing == nil} class="btn btn-primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New text template
          </button>
        </div>
      </div>

      <div :if={@uploading} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">
          {(@upload_parent && "Fork \"#{@upload_parent.name}\" — upload the revision") ||
            "Upload a Word template"}
        </h2>

        <p :if={@upload_parent} class="text-sm opacity-70">
          The original stays canonical; nodes bound to it keep rendering it. Leave the
          file empty to fork an identical copy.
        </p>

        <p class="text-sm opacity-70">
          Author it in Word with Jinja tags: <code>{"{{ client.name }}"}</code>
          inline, <code>{"{%p if ... %}"}</code>
          / <code>{"{%p endfor %}"}</code>
          on their own
          paragraphs to include or repeat whole paragraphs, and <code>{"{%tr for ... %}"}</code>
          rows for repeating table rows. Tags are
          validated on upload.
        </p>

        <form
          phx-submit="save_docx"
          phx-change="validate_docx"
          id="docx-upload-form"
          class="space-y-3"
        >
          <div class="flex gap-2 flex-wrap items-center">
            <input
              type="text"
              name="name"
              value={(@upload_parent && @upload_parent.name <> " (fork)") || ""}
              placeholder="Engagement letter"
              required
              class="input input-bordered input-sm w-64"
            />
            <input
              type="text"
              name="description"
              value={(@upload_parent && @upload_parent.description) || ""}
              placeholder="Description (optional)"
              class="input input-bordered input-sm flex-1 min-w-48"
            />
          </div>

          <.live_file_input
            upload={@uploads.docx}
            class="file-input file-input-bordered file-input-sm"
          />
          <p :for={err <- upload_errors(@uploads.docx)} class="text-sm text-error">{inspect(err)}</p>

          <p :if={@upload_error} class="text-sm text-error">{@upload_error}</p>

          <div class="flex gap-2">
            <button class="btn btn-primary btn-sm">Upload</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel">Cancel</button>
          </div>
        </form>
      </div>

      <div :if={@editing} class="card border border-base-200 p-6 space-y-3">
        <p :if={@editing["fork_of"]} class="text-sm opacity-70">
          <.icon name="hero-arrow-path-rounded-square" class="size-4 inline" />
          Forking — saving creates a new canonical template; the original never changes.
        </p>

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
            <h2 class="font-semibold">
              {template.name}
              <span :if={template.kind == "docx"} class="badge badge-accent badge-xs align-middle">
                Word
              </span>
            </h2>

            <div :if={@can_edit} class="flex gap-1">
              <button
                class="btn btn-ghost btn-xs"
                phx-click="fork"
                phx-value-template-id={template.id}
                title="Templates are canonical — revise by forking a copy"
              >
                Fork
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

          <p :if={template.parent_id} class="text-xs opacity-60">
            <.icon name="hero-arrow-path-rounded-square" class="size-3 inline" />
            forked from {parent_name(@templates, template.parent_id)}
          </p>

          <p :if={@usages[template.id]} class="text-xs opacity-70">
            <.icon name="hero-link" class="size-3 inline" />
            used by {usage_count(@usages[template.id])} node(s) in {@usages[template.id]
            |> Enum.map(& &1.name)
            |> Enum.join(", ")}
          </p>

          <button
            :if={@can_edit and template.parent_id != nil and @usages[template.parent_id] != nil}
            class="btn btn-outline btn-xs w-fit"
            phx-click="adopt"
            phx-value-template-id={template.id}
            data-confirm={"Rebind every draft node using \"#{parent_name(@templates, template.parent_id)}\" to this fork? Published versions stay as they are until republished."}
            title="Adopt this fork: draft nodes bound to the parent rebind to this template"
          >
            <.icon name="hero-arrow-right-circle" class="size-3" /> Adopt (rebind from parent)
          </button>
          <pre
            :if={template.kind != "docx"}
            class="rounded bg-base-200 p-2 text-xs overflow-hidden max-h-20"
          >{String.slice(template.content || "", 0, 240)}</pre>
          <div :if={template.kind == "docx"} class="space-y-2">
            <div class="flex flex-wrap gap-1">
              <span :for={variable <- template.variables} class="badge badge-ghost badge-xs font-mono">
                {variable}
              </span>
              <span :if={template.variables == []} class="text-xs opacity-50">
                no variables found
              </span>
            </div>

            <button
              :if={@can_edit}
              class="btn btn-accent btn-xs w-fit"
              phx-click="scaffold"
              phx-value-template-id={template.id}
              title="Generate a flux: a form asking for every variable, ending in the filled document"
            >
              <.icon name="hero-bolt" class="size-3" /> Create interview flux
            </button>
            <details class="text-xs">
              <summary class="cursor-pointer opacity-70">
                Test render — download a filled copy
              </summary>

              <form
                method="post"
                action={~p"/console/templates/#{template.id}/test-render"}
                class="mt-2 space-y-2"
              >
                <input
                  type="hidden"
                  name="_csrf_token"
                  value={Phoenix.Controller.get_csrf_token()}
                /> <textarea
                  name="context"
                  rows="4"
                  class="textarea textarea-bordered font-mono text-xs w-full"
                  placeholder="{&quot;client&quot;: {&quot;name&quot;: &quot;Ada&quot;}}"
                ></textarea> <button class="btn btn-outline btn-xs">Render &amp; download</button>
              </form>
            </details>

            <a
              href={~p"/console/templates/#{template.id}/file"}
              class="link text-xs"
              title="Download the original template"
            >
              Download original
            </a>
          </div>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
