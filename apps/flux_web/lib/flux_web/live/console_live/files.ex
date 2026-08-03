defmodule FluxWeb.ConsoleLive.Files do
  @moduledoc """
  Workspace file browser: every stored file — run outputs (documents,
  file_output, code artifacts) and chat uploads — with size, type, and a
  download link where a token exists.
  """
  use FluxWeb, :live_view

  alias Flux.Registry
  alias Flux.Workflows

  @page_size 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Files", limit: @page_size)
     |> load_files()}
  end

  defp load_files(socket) do
    scope = socket.assigns.current_scope
    files = Workflows.list_workspace_files(scope, socket.assigns.limit)

    assign(socket,
      files: files,
      more?: length(files) >= socket.assigns.limit,
      models: Registry.list(scope)
    )
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> update(:limit, &(&1 + @page_size)) |> load_files()}
  end

  def handle_event("register_model", %{"file-id" => file_id, "name" => name}, socket) do
    case Registry.register(socket.assigns.current_scope, name, file_id) do
      {:ok, artifact} ->
        {:noreply,
         socket
         |> put_flash(:info, "Registered #{artifact.name} v#{artifact.version}.")
         |> load_files()}

      {:error, :blank_name} ->
        {:noreply, put_flash(socket, :error, "Give the model a name first.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not register the model.")}
    end
  end

  def handle_event("delete_model", %{"artifact-id" => artifact_id}, socket) do
    Registry.delete(socket.assigns.current_scope, artifact_id)
    {:noreply, load_files(socket)}
  end

  defp humanize_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp humanize_bytes(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{div(bytes, 1024)} KB"

  defp humanize_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp humanize_bytes(_other), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:files}
    >
      <div>
        <h1 class="text-2xl font-bold">{gettext("Files")}</h1>
        <p class="opacity-70 mt-1">
          {gettext("Everything the workspace has stored — run outputs, artifacts, uploads.")}
        </p>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="files-card">
        <p :if={@files == []} class="text-sm opacity-60">
          Nothing stored yet — files appear when runs produce documents,
          reports, or artifacts, or when chats receive uploads.
        </p>

        <table :if={@files != []} class="table table-sm">
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>Size</th>
              <th>When</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={file <- @files} id={"file-#{file.id}"}>
              <td class="font-mono text-xs">{file.name}</td>
              <td class="text-xs opacity-70">{file.content_type}</td>
              <td class="text-xs">{humanize_bytes(file.size)}</td>
              <td class="text-xs opacity-70">
                {Calendar.strftime(file.inserted_at, "%m-%d %H:%M")}
              </td>
              <td class="whitespace-nowrap">
                <a
                  :if={file.download_token}
                  href={"/files/#{file.download_token}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-down-tray" class="size-3" /> Download
                </a>
                <form phx-submit="register_model" class="inline-flex gap-1">
                  <input type="hidden" name="file-id" value={file.id} />
                  <input
                    type="text"
                    name="name"
                    placeholder="model name"
                    class="input input-xs w-28"
                    title="Register this file in the model registry (version auto-increments)"
                  />
                  <button class="btn btn-ghost btn-xs">★ Register</button>
                </form>
              </td>
            </tr>
          </tbody>
        </table>

        <button :if={@more?} class="btn btn-ghost btn-sm" phx-click="load_more">
          Load more
        </button>
      </div>

      <div :if={@models != []} class="card border border-base-200 p-6 space-y-3" id="models-card">
        <h2 class="font-semibold">Model registry</h2>
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Name</th>
              <th>Version</th>
              <th>File</th>
              <th>Registered</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={artifact <- @models} id={"model-#{artifact.id}"}>
              <td class="font-semibold">{artifact.name}</td>
              <td><span class="badge badge-ghost badge-xs">v{artifact.version}</span></td>
              <td class="font-mono text-xs">{artifact.file.name}</td>
              <td class="text-xs opacity-70">
                {Calendar.strftime(artifact.inserted_at, "%m-%d %H:%M")}
              </td>
              <td>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_model"
                  phx-value-artifact-id={artifact.id}
                  data-confirm="Remove this registry entry? (The file itself stays.)"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p class="text-xs opacity-60">
          Registered models lead the attachment picker in the flux editor —
          serve by name, not by file id.
        </p>
      </div>
    </Layouts.console>
    """
  end
end
