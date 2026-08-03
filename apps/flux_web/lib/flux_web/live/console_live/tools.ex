defmodule FluxWeb.ConsoleLive.Tools do
  @moduledoc """
  Custom API tools: import an OpenAPI spec (JSON or YAML) and manage each
  toolset's encrypted auth and private variables. Secrets are write-only —
  the UI only ever shows names and types.
  """
  use FluxWeb, :live_view

  alias Flux.RBAC
  alias Flux.Tools
  alias Flux.Tools.ApiToolset

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "Tools",
       importing: false,
       expanded_id: nil,
       can_manage: RBAC.can?(scope, :tool_manage)
     )
     |> load_toolsets()}
  end

  defp load_toolsets(socket) do
    toolsets = Tools.list_toolsets(socket.assigns.current_scope)
    summaries = Map.new(toolsets, &{&1.id, Tools.security_summary(&1)})
    assign(socket, toolsets: toolsets, summaries: summaries)
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, assign(socket, importing: true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, importing: false)}

  def handle_event("import", %{"name" => name, "spec" => spec}, socket) do
    case Tools.create_toolset(socket.assigns.current_scope, name, spec) do
      {:ok, toolset} ->
        {:noreply,
         socket
         |> put_flash(:info, "Imported #{length(toolset.operations)} operation(s).")
         |> assign(importing: false, expanded_id: toolset.id)
         |> load_toolsets()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {field, {message, _meta}} = hd(changeset.errors)
        {:noreply, put_flash(socket, :error, "Could not import: #{field} #{message}.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage tools.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("expand", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_id: expanded)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %ApiToolset{} = toolset <- Tools.get_toolset(socket.assigns.current_scope, id),
         {:ok, _deleted} <- Tools.delete_toolset(socket.assigns.current_scope, toolset) do
      {:noreply, socket |> put_flash(:info, "Toolset deleted.") |> load_toolsets()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not delete that toolset.")}
    end
  end

  def handle_event("save_auth", %{"toolset-id" => id} = params, socket) do
    auth = %{
      "type" => params["type"] || "none",
      "in" => params["in"] || "header",
      "name" => params["name"] || "",
      "value" => params["value"] || ""
    }

    with %ApiToolset{} = toolset <- Tools.get_toolset(socket.assigns.current_scope, id),
         {:ok, _updated} <- Tools.put_auth(socket.assigns.current_scope, toolset, auth) do
      {:noreply, socket |> put_flash(:info, "Auth saved (encrypted).") |> load_toolsets()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not save auth.")}
    end
  end

  def handle_event(
        "add_variable",
        %{"toolset-id" => id, "name" => name, "value" => value},
        socket
      ) do
    name = String.trim(name)

    with true <- name != "",
         %ApiToolset{} = toolset <- Tools.get_toolset(socket.assigns.current_scope, id),
         {:ok, _updated} <-
           Tools.merge_variable(socket.assigns.current_scope, toolset, name, value) do
      {:noreply, socket |> put_flash(:info, "Variable saved (encrypted).") |> load_toolsets()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not save that variable.")}
    end
  end

  def handle_event("remove_variable", %{"id" => id, "name" => name}, socket) do
    with %ApiToolset{} = toolset <- Tools.get_toolset(socket.assigns.current_scope, id),
         {:ok, _updated} <-
           Tools.delete_variable(socket.assigns.current_scope, toolset, name) do
      {:noreply, socket |> load_toolsets()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not remove that variable.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:tools}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Tools")}</h1>

          <p class="opacity-70 mt-1">
            Import an OpenAPI spec; every operation becomes callable from the Flux canvas.
          </p>
        </div>

        <button :if={@can_manage and not @importing} class="btn btn-primary" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> Import API
        </button>
      </div>

      <div :if={@importing} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Import an OpenAPI spec</h2>

        <form phx-submit="import" class="space-y-3">
          <label class="floating-label">
            <span>Name (optional — defaults to the spec title)</span>
            <input type="text" name="name" class="input w-full" placeholder="Petstore" />
          </label>
          <label class="floating-label">
            <span>OpenAPI 3.x / Swagger 2 — JSON or YAML</span> <textarea
              name="spec"
              rows="12"
              class="textarea w-full font-mono text-xs"
              placeholder={"{\n  \"openapi\": \"3.0.0\",\n  ...\n}"}
            ></textarea>
          </label>
          <div class="flex gap-2">
            <button class="btn btn-primary">Import</button>
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          </div>
        </form>
      </div>

      <div
        :if={@toolsets == [] and not @importing}
        class="card border border-dashed border-base-300 p-12 text-center space-y-3"
      >
        <.icon name="hero-wrench-screwdriver" class="size-10 text-primary mx-auto" />
        <h2 class="font-semibold text-lg">No tools yet</h2>

        <p class="opacity-70 text-sm">Import any API's OpenAPI spec to call it from your fluxes.</p>
      </div>

      <div
        :for={toolset <- @toolsets}
        class="card border border-base-200"
        id={"toolset-#{toolset.id}"}
      >
        <button
          type="button"
          class="w-full flex items-center gap-3 p-4 text-left hover:bg-base-200/40 rounded-t-box"
          phx-click="expand"
          phx-value-id={toolset.id}
        >
          <.icon name="hero-wrench-screwdriver" class="size-5 text-primary shrink-0" />
          <div class="min-w-0 flex-1">
            <p class="font-semibold">{toolset.name}</p>

            <p class="text-xs opacity-60 truncate">{toolset.base_url}</p>
          </div>
          <span class="badge badge-ghost badge-sm">{length(toolset.operations)} operations</span>
          <span class={[
            "badge badge-sm",
            (@summaries[toolset.id].auth_type == "none" && "badge-warning") || "badge-success"
          ]}>
            auth: {@summaries[toolset.id].auth_type}
          </span>
          <.icon
            name={(@expanded_id == toolset.id && "hero-chevron-up") || "hero-chevron-down"}
            class="size-4 opacity-60"
          />
        </button>
        <div :if={@expanded_id == toolset.id} class="border-t border-base-200 p-4 space-y-6">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Operation</th>

                  <th>Method</th>

                  <th>Path</th>

                  <th>Params</th>
                </tr>
              </thead>

              <tbody>
                <tr :for={operation <- toolset.operations}>
                  <td class="font-mono text-xs">{operation["operation_id"]}</td>

                  <td>
                    <span class="badge badge-outline badge-sm uppercase">{operation["method"]}</span>
                  </td>

                  <td class="font-mono text-xs">{operation["path"]}</td>

                  <td class="text-xs opacity-70">
                    {Enum.map_join(operation["params"], ", ", & &1["name"])}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@can_manage} class="grid gap-6 lg:grid-cols-2">
            <div class="space-y-2">
              <h3 class="font-semibold text-sm">Authentication</h3>

              <p class="text-xs opacity-60">
                Stored encrypted with this workspace's key; never shown again.
              </p>

              <form phx-submit="save_auth" class="space-y-2">
                <input type="hidden" name="toolset-id" value={toolset.id} />
                <div class="flex gap-2">
                  <select name="type" class="select select-sm">
                    <option
                      :for={type <- Tools.auth_types()}
                      value={type}
                      selected={@summaries[toolset.id].auth_type == type}
                    >
                      {type}
                    </option>
                  </select>
                  <select name="in" class="select select-sm">
                    <option value="header">header</option>

                    <option value="query">query</option>
                  </select>
                </div>

                <input
                  type="text"
                  name="name"
                  placeholder="Header/param name (e.g. X-API-Key)"
                  class="input input-sm w-full"
                />
                <input
                  type="password"
                  name="value"
                  placeholder="Secret value"
                  class="input input-sm w-full"
                /> <button class="btn btn-sm btn-outline">Save auth</button>
              </form>
            </div>

            <div class="space-y-2">
              <h3 class="font-semibold text-sm">Private variables</h3>

              <p class="text-xs opacity-60">
                Encrypted; reference them in tool arguments as <code class="font-mono">{"{{vars.name}}"}</code>. Values are never displayed.
              </p>

              <div class="flex flex-wrap gap-1">
                <span
                  :for={name <- @summaries[toolset.id].variable_names}
                  class="badge badge-ghost gap-1"
                >
                  <.icon name="hero-lock-closed-micro" class="size-3" /> {name}
                  <button
                    type="button"
                    class="text-error"
                    phx-click="remove_variable"
                    phx-value-id={toolset.id}
                    phx-value-name={name}
                    data-confirm={"Remove variable #{name}?"}
                  >
                    ✕
                  </button>
                </span>
              </div>

              <form phx-submit="add_variable" class="flex gap-2">
                <input type="hidden" name="toolset-id" value={toolset.id} />
                <input
                  type="text"
                  name="name"
                  placeholder="name"
                  class="input input-sm w-32"
                />
                <input
                  type="password"
                  name="value"
                  placeholder="secret value"
                  class="input input-sm flex-1"
                /> <button class="btn btn-sm btn-outline">Add</button>
              </form>
            </div>
          </div>

          <div :if={@can_manage} class="flex justify-end">
            <button
              class="btn btn-ghost btn-sm text-error"
              phx-click="delete"
              phx-value-id={toolset.id}
              data-confirm={"Delete #{toolset.name} and all its operations?"}
            >
              Delete toolset
            </button>
          </div>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
