defmodule FluxWeb.ConsoleLive.Knowledge do
  @moduledoc """
  Knowledge bases: create datasets, add documents (pasted text or file
  upload through the native extractor), watch indexing, browse segments,
  and hit-test retrieval.
  """
  use FluxWeb, :live_view

  alias Flux.Providers
  alias Flux.RAG
  alias Flux.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    embedding_models =
      for %{model: %{type: :text_embedding}} = entry <- Providers.available_models(scope),
          do: entry

    installed = MapSet.new(Flux.Tools.list_installed_plugin_ids(scope))

    datasource_plugins =
      Enum.filter(plugin_runtime().list_datasource_plugins(), &MapSet.member?(installed, &1.id))

    {:ok,
     socket
     |> assign(
       page_title: "Knowledge",
       creating: false,
       embedding_models: embedding_models,
       datasource_plugins: datasource_plugins,
       can_edit: RBAC.can?(scope, :dataset_edit),
       can_create: RBAC.can?(scope, :dataset_create_and_management),
       selected: nil,
       documents: [],
       expanded_document_id: nil,
       editing_segment_id: nil,
       segments: [],
       hits: nil
     )
     |> allow_upload(:document,
       accept: ~w(.txt .md .markdown .csv .json .html .htm),
       max_entries: 5,
       max_file_size: 15_000_000
     )
     |> assign(datasets: RAG.list_datasets(scope))}
  end

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  defp refresh_segments(socket) do
    case socket.assigns.expanded_document_id do
      nil ->
        socket

      document_id ->
        assign(socket,
          segments: RAG.list_segments(socket.assigns.current_scope, document_id, 50)
        )
    end
  end

  defp refresh_documents(socket) do
    case socket.assigns.selected do
      nil ->
        assign(socket, documents: [])

      dataset ->
        assign(socket,
          documents: RAG.list_documents(socket.assigns.current_scope, dataset.id)
        )
    end
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, assign(socket, creating: true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, creating: false)}

  def handle_event("create", params, socket) do
    scope = socket.assigns.current_scope

    {plugin_id, model} =
      case String.split(params["embedding_choice"] || "", "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _other -> {"", ""}
      end

    case RAG.create_dataset(scope, %{
           "name" => params["name"],
           "description" => params["description"],
           "embedding_plugin_id" => plugin_id,
           "embedding_model" => model
         }) do
      {:ok, dataset} ->
        {:noreply,
         socket
         |> assign(creating: false, datasets: RAG.list_datasets(scope), selected: dataset)
         |> refresh_documents()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to create datasets.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Name and embedding model are required.")}
    end
  end

  def handle_event("select", %{"dataset-id" => id}, socket) do
    case RAG.get_dataset(socket.assigns.current_scope, id) do
      {:error, :not_found} ->
        {:noreply, socket}

      dataset ->
        {:noreply,
         socket
         |> assign(selected: dataset, hits: nil, expanded_document_id: nil, segments: [])
         |> refresh_documents()}
    end
  end

  def handle_event("delete_dataset", %{"dataset-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with dataset when not is_tuple(dataset) <- RAG.get_dataset(scope, id),
         {:ok, _} <- RAG.delete_dataset(scope, dataset) do
      {:noreply,
       socket
       |> put_flash(:info, "Dataset deleted.")
       |> assign(datasets: RAG.list_datasets(scope), selected: nil, documents: [])}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not delete that dataset.")}
    end
  end

  def handle_event("add_text", %{"name" => name, "content" => content}, socket) do
    scope = socket.assigns.current_scope

    with %{} = dataset <- socket.assigns.selected,
         true <- String.trim(content) != "" || :empty,
         {:ok, _document} <-
           RAG.add_document(scope, dataset, %{
             name: presence(name) || "pasted-#{System.unique_integer([:positive])}.txt",
             content: content
           }) do
      {:noreply, socket |> put_flash(:info, "Indexing started.") |> refresh_documents()}
    else
      :empty -> {:noreply, put_flash(socket, :error, "Paste some text first.")}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "No permission.")}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("add_url", %{"url" => url}, socket) do
    with %{} = dataset <- socket.assigns.selected,
         {:ok, _document} <-
           RAG.add_document_from_url(socket.assigns.current_scope, dataset, String.trim(url)) do
      {:noreply, socket |> put_flash(:info, "Fetched — indexing started.") |> refresh_documents()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _other ->
        {:noreply, put_flash(socket, :error, "Could not fetch that URL.")}
    end
  end

  def handle_event("sync_datasource", %{"plugin_id" => plugin_id}, socket) do
    with %{} = dataset <- socket.assigns.selected,
         {:ok, _job} <- RAG.sync_datasource(socket.assigns.current_scope, dataset, plugin_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Sync started — refresh to see new documents.")
       |> refresh_documents()}
    else
      {:error, :plugin_not_installed} ->
        {:noreply, put_flash(socket, :error, "That datasource is not installed.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "No permission.")}

      _other ->
        {:noreply, put_flash(socket, :error, "Could not start the sync.")}
    end
  end

  def handle_event("save_auto_sync", params, socket) do
    scope = socket.assigns.current_scope

    with %{} = dataset <- socket.assigns.selected,
         {:ok, updated} <-
           RAG.update_dataset(scope, dataset, %{
             "sync_plugin_id" => params["sync_plugin_id"],
             "sync_interval_minutes" => params["sync_interval_minutes"]
           }) do
      message =
        if updated.sync_plugin_id,
          do: "Auto-sync every #{updated.sync_interval_minutes} minutes.",
          else: "Auto-sync turned off."

      {:noreply, socket |> put_flash(:info, message) |> assign(selected: updated)}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not save auto-sync settings.")}
    end
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    scope = socket.assigns.current_scope
    dataset = socket.assigns.selected

    results =
      consume_uploaded_entries(socket, :document, fn %{path: path}, entry ->
        content = File.read!(path)

        content =
          if entry.client_name =~ ~r/\.html?$/i do
            case Floki.parse_document(content) do
              {:ok, document} -> document |> Floki.text(sep: " ") |> String.trim()
              _error -> content
            end
          else
            content
          end

        {:ok, RAG.add_document(scope, dataset, %{name: entry.client_name, content: content})}
      end)

    ok = Enum.count(results, &match?({:ok, _}, &1))

    {:noreply,
     socket
     |> put_flash(:info, "#{ok} document(s) queued for indexing.")
     |> refresh_documents()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_documents(socket)}
  end

  def handle_event("delete_document", %{"document-id" => id}, socket) do
    RAG.delete_document(socket.assigns.current_scope, id)
    {:noreply, refresh_documents(socket)}
  end

  def handle_event("expand_document", %{"document-id" => id}, socket) do
    if socket.assigns.expanded_document_id == id do
      {:noreply, assign(socket, expanded_document_id: nil, segments: [])}
    else
      {:noreply,
       assign(socket,
         expanded_document_id: id,
         editing_segment_id: nil,
         segments: RAG.list_segments(socket.assigns.current_scope, id, 50)
       )}
    end
  end

  def handle_event("edit_segment", %{"segment-id" => id}, socket) do
    {:noreply, assign(socket, editing_segment_id: id)}
  end

  def handle_event("cancel_segment_edit", _params, socket) do
    {:noreply, assign(socket, editing_segment_id: nil)}
  end

  def handle_event("save_segment", %{"segment-id" => id, "content" => content}, socket) do
    case RAG.update_segment(socket.assigns.current_scope, id, content) do
      {:ok, _segment} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Segment re-embedded. (A dataset re-index rebuilds from the original document text.)"
         )
         |> assign(editing_segment_id: nil)
         |> refresh_segments()}

      {:error, :empty} ->
        {:noreply, put_flash(socket, :error, "Segment text cannot be empty.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the segment.")}
    end
  end

  def handle_event("toggle_segment", %{"segment-id" => id, "enabled" => enabled}, socket) do
    RAG.set_segment_enabled(socket.assigns.current_scope, id, enabled == "true")
    {:noreply, refresh_segments(socket)}
  end

  def handle_event("delete_segment", %{"segment-id" => id}, socket) do
    RAG.delete_segment(socket.assigns.current_scope, id)
    {:noreply, socket |> refresh_segments() |> refresh_documents()}
  end

  def handle_event("save_dataset_settings", params, socket) do
    with %{} = dataset <- socket.assigns.selected,
         {:ok, updated} <-
           RAG.update_dataset(socket.assigns.current_scope, dataset, %{
             "chunk_size" => params["chunk_size"],
             "chunk_overlap" => params["chunk_overlap"],
             "retrieval_top_k" => params["retrieval_top_k"],
             "score_threshold" => params["score_threshold"]
           }) do
      {:noreply,
       socket
       |> put_flash(:info, "Settings saved — re-index to apply chunking to existing documents.")
       |> assign(selected: updated, datasets: RAG.list_datasets(socket.assigns.current_scope))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not save the settings.")}
    end
  end

  def handle_event("reindex", _params, socket) do
    with %{} = dataset <- socket.assigns.selected,
         {:ok, count} <- RAG.reindex_dataset(socket.assigns.current_scope, dataset) do
      {:noreply,
       socket
       |> put_flash(:info, "#{count} document(s) queued for re-indexing.")
       |> refresh_documents()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not re-index.")}
    end
  end

  def handle_event("hit_test", %{"query" => query}, socket) do
    with %{} = dataset <- socket.assigns.selected,
         {:ok, hits} <- RAG.retrieve(socket.assigns.current_scope, dataset.id, query) do
      {:noreply, assign(socket, hits: hits)}
    else
      _error -> {:noreply, socket}
    end
  end

  defp presence(nil), do: nil
  defp presence(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:knowledge}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Knowledge</h1>
          <p class="opacity-70 mt-1">Document collections your fluxes can retrieve from.</p>
        </div>
        <button :if={@can_create and not @creating} class="btn btn-primary" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> New dataset
        </button>
      </div>

      <div :if={@creating} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Create a dataset</h2>
        <p :if={@embedding_models == []} class="text-sm text-warning">
          No embedding models available — configure a provider under Plugins first.
        </p>
        <form phx-submit="create" id="dataset-form" class="space-y-3">
          <input
            type="text"
            name="name"
            required
            placeholder="Company handbook"
            class="input input-bordered w-full max-w-md"
          />
          <input
            type="text"
            name="description"
            placeholder="Description (optional)"
            class="input input-bordered w-full max-w-md"
          />
          <select name="embedding_choice" class="select select-bordered w-full max-w-md">
            <option
              :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @embedding_models}
              value={"#{pid}|#{m.name}"}
            >
              {pname} — {m.label}
            </option>
          </select>
          <div class="flex gap-2">
            <button class="btn btn-primary" disabled={@embedding_models == []}>Create</button>
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          </div>
        </form>
      </div>

      <div class="flex gap-4 items-start">
        <div class="w-64 shrink-0 space-y-2">
          <div
            :for={dataset <- @datasets}
            class={[
              "card border p-3 cursor-pointer hover:border-primary/60",
              (@selected && @selected.id == dataset.id && "border-primary") || "border-base-200"
            ]}
            phx-click="select"
            phx-value-dataset-id={dataset.id}
            id={"dataset-#{dataset.id}"}
          >
            <p class="font-semibold text-sm">{dataset.name}</p>
            <p class="text-xs opacity-60">{dataset.embedding_model}</p>
          </div>
          <p :if={@datasets == []} class="text-sm opacity-60">No datasets yet.</p>
        </div>

        <div :if={@selected} class="flex-1 min-w-0 space-y-4">
          <div class="flex items-center justify-between">
            <h2 class="font-semibold text-lg">{@selected.name}</h2>
            <div class="flex gap-2">
              <button class="btn btn-ghost btn-sm" phx-click="refresh" title="Refresh statuses">
                <.icon name="hero-arrow-path" class="size-4" />
              </button>
              <button
                :if={@can_create}
                class="btn btn-ghost btn-sm text-error"
                phx-click="delete_dataset"
                phx-value-dataset-id={@selected.id}
                data-confirm={"Delete #{@selected.name} and all its documents?"}
              >
                Delete dataset
              </button>
            </div>
          </div>

          <div :if={@can_edit} class="card border border-base-200 p-4 space-y-2">
            <p class="text-sm font-semibold">Chunking &amp; retrieval</p>
            <form
              phx-submit="save_dataset_settings"
              id="dataset-settings-form"
              class="flex items-end gap-2 flex-wrap"
            >
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Chunk size (200–4000)</span>
                <input
                  type="number"
                  name="chunk_size"
                  value={@selected.chunk_size}
                  min="200"
                  max="4000"
                  class="input input-bordered input-sm w-32"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Overlap (0–500)</span>
                <input
                  type="number"
                  name="chunk_overlap"
                  value={@selected.chunk_overlap}
                  min="0"
                  max="500"
                  class="input input-bordered input-sm w-28"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Top K (default 4)</span>
                <input
                  type="number"
                  name="retrieval_top_k"
                  value={@selected.retrieval_top_k}
                  min="1"
                  max="20"
                  placeholder="4"
                  class="input input-bordered input-sm w-24"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Score threshold (0–1)</span>
                <input
                  type="number"
                  name="score_threshold"
                  value={@selected.score_threshold}
                  min="0"
                  max="1"
                  step="0.01"
                  placeholder="off"
                  class="input input-bordered input-sm w-28"
                />
              </label>
              <button class="btn btn-primary btn-sm">Save</button>
              <button
                type="button"
                class="btn btn-outline btn-sm"
                phx-click="reindex"
                data-confirm="Re-chunk and re-embed every document in this dataset?"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Re-index all
              </button>
            </form>
          </div>

          <div :if={@can_edit} class="card border border-base-200 p-4 space-y-3">
            <p class="text-sm font-semibold">Add documents</p>
            <form phx-submit="upload" phx-change="validate_upload" class="space-y-2">
              <.live_file_input upload={@uploads.document} class="file-input file-input-sm" />
              <p :for={entry <- @uploads.document.entries} class="text-xs opacity-70">
                {entry.client_name} — {entry.progress}%
              </p>
              <button
                :if={@uploads.document.entries != []}
                class="btn btn-primary btn-sm"
              >
                Index uploads
              </button>
            </form>
            <form phx-submit="add_url" class="flex gap-2" id="url-form">
              <input
                type="url"
                name="url"
                placeholder="…or fetch a page: https://example.com/docs"
                class="input input-bordered input-sm flex-1"
              />
              <button class="btn btn-outline btn-sm">Fetch &amp; index</button>
            </form>
            <form
              :if={@datasource_plugins != []}
              phx-submit="sync_datasource"
              class="flex gap-2"
              id="datasource-sync-form"
            >
              <select name="plugin_id" class="select select-bordered select-sm flex-1">
                <option :for={plugin <- @datasource_plugins} value={plugin.id}>
                  {plugin.name}
                </option>
              </select>
              <button class="btn btn-outline btn-sm">Sync datasource</button>
            </form>
            <form
              :if={@datasource_plugins != []}
              phx-submit="save_auto_sync"
              class="flex items-end gap-2 flex-wrap"
              id="auto-sync-form"
            >
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Auto-sync source</span>
                <select name="sync_plugin_id" class="select select-bordered select-sm">
                  <option value="">Off</option>
                  <option
                    :for={plugin <- @datasource_plugins}
                    value={plugin.id}
                    selected={@selected.sync_plugin_id == plugin.id}
                  >
                    {plugin.name}
                  </option>
                </select>
              </label>
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Every (minutes, ≥ 5)</span>
                <input
                  type="number"
                  name="sync_interval_minutes"
                  min="5"
                  value={@selected.sync_interval_minutes || 60}
                  class="input input-bordered input-sm w-28"
                />
              </label>
              <button class="btn btn-outline btn-sm">Save auto-sync</button>
            </form>
            <form phx-submit="add_text" class="space-y-2" id="paste-form">
              <input
                type="text"
                name="name"
                placeholder="Document name (optional)"
                class="input input-bordered input-sm w-full max-w-md"
              />
              <textarea
                name="content"
                rows="3"
                placeholder="…or paste text here"
                class="textarea textarea-bordered textarea-sm w-full"
              ></textarea>
              <button class="btn btn-outline btn-sm">Index pasted text</button>
            </form>
          </div>

          <div class="card border border-base-200 p-4 space-y-2">
            <p class="text-sm font-semibold">Documents</p>
            <p :if={@documents == []} class="text-sm opacity-60">Nothing indexed yet.</p>
            <div :for={document <- @documents} class="rounded-box border border-base-200">
              <button
                type="button"
                class="w-full flex items-center gap-2 px-3 py-2 text-left hover:bg-base-200/60"
                phx-click="expand_document"
                phx-value-document-id={document.id}
              >
                <span class="text-sm font-medium truncate">{document.name}</span>
                <span class={[
                  "badge badge-sm",
                  document.status == :ready && "badge-success",
                  document.status == :error && "badge-error",
                  document.status in [:pending, :indexing] && "badge-info"
                ]}>
                  {document.status}
                </span>
                <span class="text-xs opacity-60">{document.segment_count} segments</span>
                <span
                  :if={@can_edit}
                  class="ml-auto btn btn-ghost btn-xs text-error"
                  phx-click="delete_document"
                  phx-value-document-id={document.id}
                >
                  ✕
                </span>
              </button>
              <div
                :if={@expanded_document_id == document.id}
                class="border-t border-base-200 p-3 space-y-2"
              >
                <p :if={document.error} class="text-sm text-error">{document.error}</p>
                <div
                  :for={segment <- @segments}
                  class={["rounded bg-base-200 p-2 text-xs", not segment.enabled && "opacity-50"]}
                  id={"segment-#{segment.id}"}
                >
                  <div
                    :if={@editing_segment_id != segment.id}
                    class="whitespace-pre-wrap max-h-32 overflow-y-auto"
                  >
                    <span class="opacity-50">#{segment.position}</span>
                    <span :if={not segment.enabled} class="badge badge-ghost badge-xs">
                      disabled
                    </span>
                    {segment.content}
                  </div>
                  <form
                    :if={@editing_segment_id == segment.id}
                    phx-submit="save_segment"
                    id={"segment-form-#{segment.id}"}
                    class="space-y-1"
                  >
                    <input type="hidden" name="segment-id" value={segment.id} />
                    <textarea
                      name="content"
                      rows="4"
                      class="textarea textarea-bordered textarea-xs w-full"
                    >{segment.content}</textarea>
                    <div class="flex gap-1">
                      <button class="btn btn-primary btn-xs">Save &amp; re-embed</button>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs"
                        phx-click="cancel_segment_edit"
                      >
                        Cancel
                      </button>
                    </div>
                  </form>
                  <div
                    :if={@can_edit and @editing_segment_id != segment.id}
                    class="mt-1 flex gap-1"
                  >
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="edit_segment"
                      phx-value-segment-id={segment.id}
                    >
                      Edit
                    </button>
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="toggle_segment"
                      phx-value-segment-id={segment.id}
                      phx-value-enabled={to_string(not segment.enabled)}
                    >
                      {(segment.enabled && "Disable") || "Enable"}
                    </button>
                    <button
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="delete_segment"
                      phx-value-segment-id={segment.id}
                      data-confirm="Delete this segment from the index?"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="card border border-base-200 p-4 space-y-2">
            <p class="text-sm font-semibold">Hit testing</p>
            <form phx-submit="hit_test" class="flex gap-2" id="hit-test-form">
              <input
                type="text"
                name="query"
                placeholder="Ask something to preview retrieval…"
                class="input input-bordered input-sm flex-1"
              />
              <button class="btn btn-primary btn-sm">Retrieve</button>
            </form>
            <p :if={@hits == []} class="text-sm opacity-60">No matches.</p>
            <div
              :for={hit <- @hits || []}
              class="rounded-box border border-base-200 p-3 space-y-1"
            >
              <p class="text-xs opacity-60">
                {hit.document.name} · score {Float.round(hit.score, 4)}
              </p>
              <p class="text-sm whitespace-pre-wrap">{hit.content}</p>
            </div>
          </div>
        </div>

        <div
          :if={@selected == nil and @datasets != []}
          class="flex-1 card border border-dashed border-base-300 p-12 text-center"
        >
          <p class="opacity-60 text-sm">Select a dataset to manage documents and test retrieval.</p>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
