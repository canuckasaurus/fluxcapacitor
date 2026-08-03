defmodule FluxWeb.ConsoleLive.Files do
  @moduledoc """
  Workspace file browser: every stored file — run outputs (documents,
  file_output, code artifacts) and chat uploads — with size, type, and a
  download link where a token exists.
  """
  use FluxWeb, :live_view

  alias Flux.Workflows

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Files",
       files: Workflows.list_workspace_files(socket.assigns.current_scope)
     )}
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
              <td>
                <a
                  :if={file.download_token}
                  href={"/files/#{file.download_token}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-down-tray" class="size-3" /> Download
                </a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
