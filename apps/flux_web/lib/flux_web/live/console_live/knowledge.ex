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

    models = Providers.available_models(scope)
    embedding_models = for %{model: %{type: :text_embedding}} = entry <- models, do: entry
    chat_models = for %{model: %{type: :llm}} = entry <- models, do: entry

    installed = MapSet.new(Flux.Tools.list_installed_plugin_ids(scope))

    datasource_plugins =
      Enum.filter(plugin_runtime().list_datasource_plugins(), &MapSet.member?(installed, &1.id))

    {:ok,
     socket
     |> assign(
       page_title: "Knowledge",
       creating: false,
       embedding_models: embedding_models,
       chat_models: chat_models,
       datasource_plugins: datasource_plugins,
       can_edit: RBAC.can?(scope, :dataset_edit),
       can_create: RBAC.can?(scope, :dataset_create_and_management),
       fluxes: Flux.Workflows.list_workflows(scope),
       selected: nil,
       retrieval_cases: [],
       retrieval_summary: nil,
       documents: [],
       url_sources: [],
       selected_doc_ids: MapSet.new(),
       doc_search_results: nil,
       expanded_document_id: nil,
       editing_segment_id: nil,
       segments: [],
       hits: nil
     )
     |> allow_upload(:document,
       accept: ~w(.txt .md .markdown .csv .json .html .htm .pdf .docx .doc .xlsx .pptx
            .png .jpg .jpeg .gif .webp .mp3 .wav .webm),
       max_entries: 5,
       max_file_size: 25_000_000
     )
     |> assign(
       datasets: RAG.list_datasets(scope),
       trashed_datasets: RAG.list_trashed_datasets(scope)
     )}
  end

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  defp bulk_set_enabled(socket, enabled) do
    ids = MapSet.to_list(socket.assigns.selected_doc_ids)

    case RAG.set_documents_enabled(socket.assigns.current_scope, ids, enabled) do
      {:ok, count} ->
        socket
        |> put_flash(:info, "#{(enabled && "Enabled") || "Disabled"} #{count} documents.")
        |> refresh_documents()

      _error ->
        put_flash(socket, :error, "Could not update the selected documents.")
    end
  end

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
        assign(socket, documents: [], url_sources: [])

      dataset ->
        assign(socket,
          documents: RAG.list_documents(socket.assigns.current_scope, dataset.id),
          url_sources: RAG.list_url_sources(socket.assigns.current_scope, dataset.id)
        )
    end
  end

  defp extract_or_describe(workspace_id, entry, binary) do
    case entry.client_type do
      "image/" <> _subtype ->
        case Flux.Workflows.describe_image_for_workspace(workspace_id, binary, entry.client_type) do
          {:ok, description} -> {:ok, "[image: #{entry.client_name}]\n\n" <> description}
          {:error, _reason} -> {:error, "no vision-capable default model configured"}
        end

      type when type in ["audio/mpeg", "audio/wav", "audio/webm", "video/webm"] ->
        case Flux.Providers.transcribe(workspace_id, binary, %{
               filename: entry.client_name,
               content_type: type
             }) do
          {:ok, %{text: text}} when text != "" ->
            {:ok, "[audio: #{entry.client_name}]\n\n" <> text}

          {:ok, _empty} ->
            {:error, "the recording transcribed to nothing"}

          {:error, _reason} ->
            {:error, "the default provider has no transcription endpoint"}
        end

      _document ->
        Flux.Documents.extract_binary(entry.client_name, entry.client_type, binary)
    end
  end

  @impl true
  def handle_event("delete_url_source", %{"source-id" => source_id}, socket) do
    RAG.delete_url_source(socket.assigns.current_scope, source_id)
    {:noreply, refresh_documents(socket)}
  end

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
         |> assign(
           creating: false,
           datasets: RAG.list_datasets(scope),
           selected: dataset,
           retrieval_cases: [],
           retrieval_summary: nil
         )
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
         |> assign(
           selected: dataset,
           hits: nil,
           expanded_document_id: nil,
           segments: [],
           retrieval_cases: RAG.list_retrieval_cases(socket.assigns.current_scope, dataset.id),
           retrieval_summary: nil
         )
         |> refresh_documents()}
    end
  end

  def handle_event("add_retrieval_case", params, socket) do
    scope = socket.assigns.current_scope

    case RAG.add_retrieval_case(scope, socket.assigns.selected, %{
           "question" => params["question"],
           "expected" => params["expected"]
         }) do
      {:ok, _case} ->
        {:noreply,
         assign(socket,
           retrieval_cases: RAG.list_retrieval_cases(scope, socket.assigns.selected.id)
         )}

      _error ->
        {:noreply, put_flash(socket, :error, "Both a question and an expected passage, please.")}
    end
  end

  def handle_event("delete_retrieval_case", %{"case-id" => case_id}, socket) do
    scope = socket.assigns.current_scope
    RAG.delete_retrieval_case(scope, case_id)

    {:noreply,
     assign(socket,
       retrieval_cases: RAG.list_retrieval_cases(scope, socket.assigns.selected.id),
       retrieval_summary: nil
     )}
  end

  def handle_event(
        "set_document_metadata",
        %{"document-id" => document_id, "metadata" => metadata},
        socket
      ) do
    parsed =
      metadata
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(&match?([_key, _value], &1))
      |> Map.new(fn [key, value] -> {key, value} end)

    case RAG.set_document_metadata(socket.assigns.current_scope, document_id, parsed) do
      {:ok, _document} ->
        {:noreply, refresh_documents(socket)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the metadata.")}
    end
  end

  def handle_event("set_document_tags", %{"document-id" => document_id, "tags" => tags}, socket) do
    case RAG.set_document_tags(
           socket.assigns.current_scope,
           document_id,
           String.split(to_string(tags), ",")
         ) do
      {:ok, _document} ->
        {:noreply, socket |> put_flash(:info, "Tags saved.") |> refresh_documents()}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the tags.")}
    end
  end

  def handle_event("run_retrieval_eval", _params, socket) do
    summary =
      RAG.evaluate_retrieval(socket.assigns.current_scope, socket.assigns.selected.id)

    {:noreply, assign(socket, retrieval_summary: summary)}
  end

  def handle_event("delete_dataset", %{"dataset-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with dataset when not is_tuple(dataset) <- RAG.get_dataset(scope, id),
         {:ok, _} <- RAG.delete_dataset(scope, dataset) do
      {:noreply,
       socket
       |> put_flash(:info, "Dataset moved to the trash (restorable for 30 days).")
       |> assign(
         datasets: RAG.list_datasets(scope),
         trashed_datasets: RAG.list_trashed_datasets(scope),
         selected: nil,
         documents: []
       )}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not delete that dataset.")}
    end
  end

  def handle_event("restore_dataset", %{"dataset-id" => id}, socket) do
    scope = socket.assigns.current_scope

    case RAG.restore_dataset(scope, id) do
      {:ok, dataset} ->
        {:noreply,
         socket
         |> put_flash(:info, "\"#{dataset.name}\" restored.")
         |> assign(
           datasets: RAG.list_datasets(scope),
           trashed_datasets: RAG.list_trashed_datasets(scope)
         )}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not restore that dataset.")}
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

  def handle_event("add_url", %{"url" => url} = params, socket) do
    scope = socket.assigns.current_scope
    url = String.trim(url)

    result =
      with %{} = dataset <- socket.assigns.selected do
        if params["crawl"] == "on" do
          RAG.crawl_from_url(scope, dataset, url)
        else
          RAG.add_document_from_url(scope, dataset, url)
        end
      end

    if params["remember"] == "on" and match?({:ok, _fetched}, result) do
      RAG.remember_url_source(scope, socket.assigns.selected, url, params["crawl"] == "on")
    end

    case result do
      {:ok, %{added: added, skipped: skipped}} ->
        note = if skipped > 0, do: " (#{skipped} linked pages skipped)", else: ""

        {:noreply,
         socket
         |> put_flash(:info, "Fetched #{added} pages#{note} â€” indexing started.")
         |> refresh_documents()}

      {:ok, _document} ->
        {:noreply,
         socket |> put_flash(:info, "Fetched â€” indexing started.") |> refresh_documents()}

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
       |> put_flash(:info, "Sync started â€” refresh to see new documents.")
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
        binary = File.read!(path)

        # Images ingest through the workspace vision model: the
        # description (with any visible text transcribed) is what
        # indexes; everything else takes the extraction pipeline.
        case extract_or_describe(dataset.workspace_id, entry, binary) do
          {:ok, content} when content != "" ->
            # Same-named uploads replace the previous version in place.
            {:ok,
             RAG.add_document(
               scope,
               dataset,
               %{name: entry.client_name, content: content},
               replace: true
             )}

          {:ok, _empty} ->
            {:ok, {:error, "#{entry.client_name}: no readable text"}}

          {:error, message} ->
            {:ok, {:error, "#{entry.client_name}: #{message}"}}
        end
      end)

    ok = Enum.count(results, &match?({:ok, _}, &1))
    failures = for {:error, message} <- results, do: message

    socket =
      if failures == [] do
        put_flash(socket, :info, "#{ok} document(s) queued for indexing.")
      else
        put_flash(socket, :error, Enum.join(failures, " · "))
      end

    {:noreply, refresh_documents(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_documents(socket)}
  end

  def handle_event("search_dataset", %{"query" => query}, socket) do
    results =
      case {socket.assigns.selected, String.trim(query)} do
        {nil, _query} ->
          nil

        {_dataset, ""} ->
          nil

        {dataset, trimmed} ->
          RAG.search_dataset(socket.assigns.current_scope, dataset.id, trimmed)
      end

    {:noreply, assign(socket, doc_search_results: results)}
  end

  def handle_event("toggle_doc_select", %{"document-id" => id}, socket) do
    selected = socket.assigns.selected_doc_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected_doc_ids: selected)}
  end

  def handle_event("clear_doc_selection", _params, socket) do
    {:noreply, assign(socket, selected_doc_ids: MapSet.new())}
  end

  def handle_event("bulk_enable_documents", _params, socket) do
    {:noreply, bulk_set_enabled(socket, true)}
  end

  def handle_event("bulk_disable_documents", _params, socket) do
    {:noreply, bulk_set_enabled(socket, false)}
  end

  def handle_event("bulk_delete_documents", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_doc_ids)

    case RAG.delete_documents(socket.assigns.current_scope, ids) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{count} documents.")
         |> assign(selected_doc_ids: MapSet.new())
         |> refresh_documents()}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not delete the selected documents.")}
    end
  end

  def handle_event("bulk_tag_documents", %{"tags" => tags}, socket) do
    ids = MapSet.to_list(socket.assigns.selected_doc_ids)

    case RAG.tag_documents(socket.assigns.current_scope, ids, String.split(tags, ",")) do
      {:ok, count} ->
        {:noreply,
         socket |> put_flash(:info, "Tagged #{count} documents.") |> refresh_documents()}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not tag the selected documents.")}
    end
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
    {entity_plugin, entity_model} =
      case String.split(params["entity_choice"] || "", "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _heuristic -> {"", ""}
      end

    with %{} = dataset <- socket.assigns.selected,
         {:ok, updated} <-
           RAG.update_dataset(socket.assigns.current_scope, dataset, %{
             "chunk_size" => params["chunk_size"],
             "chunk_overlap" => params["chunk_overlap"],
             "split_markdown" => params["split_markdown"] == "on",
             "parent_child" => params["parent_child"] == "on",
             "query_expansion" => params["query_expansion"] == "on",
             "retrieval_top_k" => params["retrieval_top_k"],
             "score_threshold" => params["score_threshold"],
             "entity_plugin_id" => entity_plugin,
             "entity_model" => entity_model,
             "retrieval_eval_cron" => params["retrieval_eval_cron"]
           }) do
      {:noreply,
       socket
       |> put_flash(:info, "Settings saved â€” re-index to apply chunking to existing documents.")
       |> assign(selected: updated, datasets: RAG.list_datasets(socket.assigns.current_scope))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not save the settings.")}
    end
  end

  def handle_event("run_flux_over_dataset", %{"workflow-id" => workflow_id}, socket) do
    scope = socket.assigns.current_scope

    with %{} = dataset <- socket.assigns.selected,
         workflow when not is_tuple(workflow) <-
           Flux.Workflows.get_workflow(scope, workflow_id) do
      rows =
        for document <- RAG.list_documents(scope, dataset.id),
            document.content not in [nil, ""] do
          content = String.slice(document.content, 0, 20_000)
          %{"query" => content, "content" => content, "name" => document.name}
        end

      case rows != [] &&
             Flux.Workflows.start_batch(scope, workflow, rows, name: "dataset: #{dataset.name}") do
        {:ok, batch} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "#{batch.total} document(s) queued through #{workflow.name} — results on the Batches page."
           )
           |> push_navigate(to: ~p"/console/fluxes/#{workflow.id}/batches")}

        false ->
          {:noreply, put_flash(socket, :error, "This dataset has no readable documents.")}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "You don't have permission to run batches.")}

        _error ->
          {:noreply, put_flash(socket, :error, "Could not start the batch.")}
      end
    else
      _missing -> {:noreply, socket}
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
          <h1 class="text-2xl font-bold">{gettext("Knowledge")}</h1>

          <p class="opacity-70 mt-1">
            {gettext("Document collections your fluxes can retrieve from.")}
          </p>
        </div>

        <button :if={@can_create and not @creating} class="btn btn-primary" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> {gettext("New dataset")}
        </button>
      </div>

      <div :if={@creating} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Create a dataset</h2>

        <p :if={@embedding_models == []} class="text-sm text-warning">
          No embedding models available â€” configure a provider under Plugins first.
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
              {pname} â€” {m.label}
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

        <div :if={@datasets == []} class="flex-1">
          <Layouts.empty_state icon="hero-book-open" title="No knowledge yet">
            <p>Create a dataset and upload documents â€” fluxes retrieve from them
              to answer with your content.</p>
          </Layouts.empty_state>
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
                <span class="label-text text-xs opacity-70 mb-1">Chunk size (200â€“4000)</span>
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
                <span class="label-text text-xs opacity-70 mb-1">Overlap (0â€“500)</span>
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
                <span class="label-text text-xs opacity-70 mb-1">Markdown-aware</span>
                <label class="label cursor-pointer justify-start gap-2 py-1">
                  <input
                    type="checkbox"
                    name="split_markdown"
                    checked={@selected.split_markdown}
                    class="checkbox checkbox-xs"
                    title="Split at headings and prefix each chunk with its heading"
                  /> <span class="text-xs opacity-70">split at headings</span>
                </label>
              </label>
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Parent-child</span>
                <label class="label cursor-pointer justify-start gap-2 py-1">
                  <input
                    type="checkbox"
                    name="parent_child"
                    checked={@selected.parent_child}
                    class="checkbox checkbox-xs"
                    title="Embed small child chunks for precise matching; retrieval returns the enclosing parent section for context"
                  /> <span class="text-xs opacity-70">child match, parent context</span>
                </label>
              </label>
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Query expansion</span>
                <label class="label cursor-pointer justify-start gap-2 py-1">
                  <input
                    type="checkbox"
                    name="query_expansion"
                    checked={@selected.query_expansion}
                    class="checkbox checkbox-xs"
                    title="Rephrase each query with the workspace model and fuse all rankings â€” better recall, one extra model call per retrieval"
                  /> <span class="text-xs opacity-70">rephrase queries</span>
                </label>
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
                <span class="label-text text-xs opacity-70 mb-1">Score threshold (0â€“1)</span>
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
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">
                  Entity extraction (falls back to heuristic on errors)
                </span>
                <select name="entity_choice" class="select select-bordered select-sm w-52">
                  <option value="" selected={@selected.entity_plugin_id in [nil, ""]}>
                    Heuristic (default)
                  </option>

                  <option
                    :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @chat_models}
                    value={"#{pid}|#{m.name}"}
                    selected={@selected.entity_plugin_id == pid and @selected.entity_model == m.name}
                  >
                    {pname} â€” {m.label}
                  </option>
                </select>
              </label>
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Retrieval eval cron</span>
                <input
                  type="text"
                  name="retrieval_eval_cron"
                  value={@selected.retrieval_eval_cron}
                  placeholder="0 6 * * *"
                  class="input input-bordered input-sm w-36 font-mono"
                  title="Scores the golden retrieval cases on this schedule; a drop in hit rate or MRR raises an eval-regressed notification"
                />
                <span
                  :if={preview = FluxWeb.CronPreview.describe(@selected.retrieval_eval_cron)}
                  class="text-[10px] opacity-50 mt-1"
                >
                  {preview}
                </span>
                <span :if={@selected.last_retrieval_eval_at} class="text-[10px] opacity-50 mt-1">
                  last: hit rate {@selected.last_retrieval_hit_rate}, MRR {@selected.last_retrieval_mrr}
                </span>
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

          <div :if={@can_edit and @fluxes != []} class="card border border-base-200 p-4 space-y-2">
            <p class="text-sm font-semibold">Run a flux over this dataset</p>
            <p class="text-xs opacity-60">
              Every document becomes a batch row (its text as <span class="font-mono">query</span>/<span class="font-mono">content</span>,
              plus <span class="font-mono">name</span>) — bulk summarize, classify, or
              extract without a CSV.
            </p>
            <form phx-submit="run_flux_over_dataset" class="flex gap-2" id="dataset-flux-form">
              <select name="workflow-id" class="select select-bordered select-sm w-64" required>
                <option value="" disabled selected>Pick a flux…</option>
                <option :for={flux <- @fluxes} value={flux.id}>{flux.name}</option>
              </select>
              <button class="btn btn-outline btn-sm">Queue batch</button>
            </form>
          </div>

          <div :if={@can_edit} class="card border border-base-200 p-4 space-y-3">
            <p class="text-sm font-semibold">Add documents</p>

            <form phx-submit="upload" phx-change="validate_upload" class="space-y-2">
              <.live_file_input upload={@uploads.document} class="file-input file-input-sm" />
              <p :for={entry <- @uploads.document.entries} class="text-xs opacity-70">
                {entry.client_name} â€” {entry.progress}%
              </p>

              <button
                :if={@uploads.document.entries != []}
                class="btn btn-primary btn-sm"
              >
                Index uploads
              </button>
            </form>

            <form phx-submit="add_url" class="flex gap-2 items-center flex-wrap" id="url-form">
              <input
                type="url"
                name="url"
                placeholder="â€¦or fetch a page: https://example.com/docs"
                class="input input-bordered input-sm flex-1"
              />
              <label
                class="flex items-center gap-1 text-xs opacity-80"
                title="Also fetch same-site pages this one links to (up to 10 total)"
              >
                <input type="checkbox" name="crawl" class="checkbox checkbox-xs" /> crawl links
              </label>
              <label
                class="flex items-center gap-1 text-xs opacity-80"
                title="Re-fetch this source nightly, replacing its documents"
              >
                <input type="checkbox" name="remember" class="checkbox checkbox-xs" /> re-fetch
                nightly
              </label>
              <button class="btn btn-outline btn-sm">Fetch &amp; index</button>
            </form>

            <div :if={@url_sources != []} class="text-xs space-y-1" id="url-sources">
              <p class="font-semibold opacity-70">Remembered sources (re-fetched nightly)</p>

              <div
                :for={source <- @url_sources}
                class="flex items-center gap-2"
                id={"url-source-#{source.id}"}
              >
                <span class="font-mono truncate max-w-md">{source.url}</span>
                <span :if={source.crawl} class="badge badge-ghost badge-xs">crawl</span>
                <span class="opacity-60">
                  {(source.last_fetched_at &&
                      "fetched " <> Calendar.strftime(source.last_fetched_at, "%b %d %H:%M")) ||
                    "not fetched yet"}
                </span>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_url_source"
                  phx-value-source-id={source.id}
                  aria-label="Forget this source"
                >
                  âœ•
                </button>
              </div>
            </div>

            <form
              :if={@datasource_plugins != []}
              phx-submit="sync_datasource"
              class="flex gap-2"
              id="datasource-sync-form"
            >
              <select name="plugin_id" class="select select-bordered select-sm flex-1">
                <option :for={plugin <- @datasource_plugins} value={plugin.id}>{plugin.name}</option>
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
                <span class="label-text text-xs opacity-70 mb-1">Every (minutes, â‰¥ 5)</span>
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
              /> <textarea
                name="content"
                rows="3"
                placeholder="â€¦or paste text here"
                class="textarea textarea-bordered textarea-sm w-full"
              ></textarea> <button class="btn btn-outline btn-sm">Index pasted text</button>
            </form>
          </div>

          <div class="card border border-base-200 p-4 space-y-2">
            <p class="text-sm font-semibold">Documents</p>

            <form phx-submit="search_dataset" class="flex gap-2" id="dataset-search-form">
              <input
                type="text"
                name="query"
                placeholder="Search this dataset's content…"
                class="input input-bordered input-sm flex-1 max-w-md"
              />
              <button class="btn btn-outline btn-sm">Search</button>
            </form>

            <p :if={@doc_search_results == []} class="text-sm opacity-60">
              No segments matched.
            </p>

            <div
              :for={hit <- @doc_search_results || []}
              class="rounded-box border border-base-200 p-3 space-y-1"
            >
              <div class="flex items-center gap-2 text-xs opacity-60">
                <span class="font-semibold">{hit.document_name}</span>
                <span>segment {hit.segment.position}</span>
                <button
                  class="btn btn-ghost btn-xs ml-auto"
                  phx-click="expand_document"
                  phx-value-document-id={hit.document_id}
                >
                  View document
                </button>
              </div>
              <p class="text-sm whitespace-pre-wrap break-words max-h-16 overflow-y-auto">
                {hit.segment.content}
              </p>
            </div>

            <p :if={@documents == []} class="text-sm opacity-60">Nothing indexed yet.</p>

            <div
              :if={@can_edit and @selected_doc_ids != MapSet.new()}
              class="flex flex-wrap items-center gap-2 rounded-box bg-base-200/60 px-3 py-2"
              id="bulk-doc-bar"
            >
              <span class="text-xs font-semibold">
                {MapSet.size(@selected_doc_ids)} selected
              </span>
              <button class="btn btn-outline btn-xs" phx-click="bulk_enable_documents">
                Enable
              </button>
              <button class="btn btn-outline btn-xs" phx-click="bulk_disable_documents">
                Disable
              </button>
              <form phx-submit="bulk_tag_documents" class="flex gap-1" id="bulk-tag-form">
                <input
                  type="text"
                  name="tags"
                  placeholder="add tags, comma-separated"
                  class="input input-bordered input-xs w-48"
                />
                <button class="btn btn-outline btn-xs">Tag</button>
              </form>
              <button
                class="btn btn-outline btn-xs text-error"
                phx-click="bulk_delete_documents"
                data-confirm="Delete the selected documents and their segments?"
              >
                Delete
              </button>
              <button class="btn btn-ghost btn-xs" phx-click="clear_doc_selection">Clear</button>
            </div>

            <div :for={document <- @documents} class="rounded-box border border-base-200">
              <div class="w-full flex items-center gap-2 px-3 py-2">
                <input
                  :if={@can_edit}
                  type="checkbox"
                  class="checkbox checkbox-xs"
                  checked={MapSet.member?(@selected_doc_ids, document.id)}
                  phx-click="toggle_doc_select"
                  phx-value-document-id={document.id}
                  id={"doc-select-#{document.id}"}
                />
                <button
                  type="button"
                  class="flex-1 flex items-center gap-2 text-left hover:bg-base-200/60 min-w-0"
                  phx-click="expand_document"
                  phx-value-document-id={document.id}
                >
                  <span class={[
                    "text-sm font-medium truncate",
                    !document.enabled && "opacity-50 line-through"
                  ]}>
                    {document.name}
                  </span>
                  <span class={[
                    "badge badge-sm",
                    document.status == :ready && "badge-success",
                    document.status == :error && "badge-error",
                    document.status in [:pending, :indexing] && "badge-info"
                  ]}>
                    {document.status}
                  </span>
                  <span :if={!document.enabled} class="badge badge-ghost badge-sm">disabled</span>
                  <span class="text-xs opacity-60">{document.segment_count} segments</span>
                  <span
                    :if={@can_edit}
                    class="ml-auto btn btn-ghost btn-xs text-error"
                    phx-click="delete_document"
                    phx-value-document-id={document.id}
                  >
                    âœ•
                  </span>
                </button>
              </div>
              <div
                :if={@expanded_document_id == document.id}
                class="border-t border-base-200 p-3 space-y-2"
              >
                <p :if={document.error} class="text-sm text-error">{document.error}</p>

                <form
                  :if={@can_edit}
                  phx-submit="set_document_tags"
                  class="flex gap-2"
                  id={"tags-form-#{document.id}"}
                >
                  <input type="hidden" name="document-id" value={document.id} />
                  <input
                    type="text"
                    name="tags"
                    value={Enum.join(document.tags, ", ")}
                    placeholder="tags, comma-separated (retrieval filters)"
                    class="input input-bordered input-xs w-64"
                  /> <button class="btn btn-ghost btn-xs">Save tags</button>
                </form>

                <form
                  :if={@can_edit}
                  phx-submit="set_document_metadata"
                  class="flex gap-2"
                  id={"metadata-form-#{document.id}"}
                >
                  <input type="hidden" name="document-id" value={document.id} />
                  <input
                    type="text"
                    name="metadata"
                    value={
                      Enum.map_join(Enum.sort(document.metadata), ", ", fn {key, value} ->
                        "#{key}=#{value}"
                      end)
                    }
                    placeholder="metadata: key=value, key=value (retrieval filters)"
                    class="input input-bordered input-xs w-64"
                  /> <button class="btn btn-ghost btn-xs">Save metadata</button>
                </form>

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
                    <span :if={not segment.enabled} class="badge badge-ghost badge-xs">disabled</span> {segment.content}
                  </div>

                  <form
                    :if={@editing_segment_id == segment.id}
                    phx-submit="save_segment"
                    id={"segment-form-#{segment.id}"}
                    class="space-y-1"
                  >
                    <input type="hidden" name="segment-id" value={segment.id} /> <textarea
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
                placeholder="Ask something to preview retrievalâ€¦"
                class="input input-bordered input-sm flex-1"
              /> <button class="btn btn-primary btn-sm">Retrieve</button>
            </form>

            <p :if={@hits == []} class="text-sm opacity-60">No matches.</p>

            <div
              :for={hit <- @hits || []}
              class="rounded-box border border-base-200 p-3 space-y-1"
            >
              <p class="text-xs opacity-60">
                {hit.document.name} Â· score {Float.round(hit.score, 4)}
              </p>

              <p class="text-sm whitespace-pre-wrap">{hit.content}</p>
            </div>
          </div>

          <div class="card border border-base-200 p-4 space-y-2" id="retrieval-evals-card">
            <div class="flex items-center gap-2">
              <p class="text-sm font-semibold">Retrieval evals</p>

              <button
                :if={@retrieval_cases != []}
                class="btn btn-primary btn-xs ml-auto"
                phx-click="run_retrieval_eval"
              >
                Score retrieval
              </button>
            </div>

            <p class="text-xs opacity-60">Golden cases: for each question, a passage containing the
              expected text should come back. Re-score after chunking or
              backend changes to see if retrieval got better or worse.</p>

            <form phx-submit="add_retrieval_case" class="flex gap-2" id="retrieval-case-form">
              <input
                type="text"
                name="question"
                placeholder="Question"
                class="input input-bordered input-sm flex-1"
              />
              <input
                type="text"
                name="expected"
                placeholder="expected passage text"
                class="input input-bordered input-sm flex-1"
              /> <button class="btn btn-sm">Add case</button>
            </form>

            <div
              :if={@retrieval_summary}
              class="rounded-box bg-base-200/50 p-2 text-sm"
              id="retrieval-summary"
            >
              Hit rate {@retrieval_summary.hit_rate} Â· MRR {@retrieval_summary.mrr} Â· {@retrieval_summary.hits}/{@retrieval_summary.total} found
            </div>

            <table :if={@retrieval_cases != []} class="table table-xs">
              <thead>
                <tr>
                  <th>Question</th>

                  <th>Expected</th>

                  <th>Rank</th>

                  <th></th>
                </tr>
              </thead>

              <tbody>
                <tr :for={retrieval_case <- @retrieval_cases} id={"rcase-#{retrieval_case.id}"}>
                  <td class="max-w-xs truncate">{retrieval_case.question}</td>

                  <td class="max-w-xs truncate opacity-70">{retrieval_case.expected}</td>

                  <td>
                    <span :if={@retrieval_summary} class="font-mono text-xs">
                      {case Enum.find(
                              @retrieval_summary.results,
                              &(&1.case_id == retrieval_case.id)
                            ) do
                        %{rank: nil} -> "miss"
                        %{rank: rank} -> "#" <> to_string(rank)
                        _not_scored -> "â€”"
                      end}
                    </span>
                  </td>

                  <td>
                    <button
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="delete_retrieval_case"
                      phx-value-case-id={retrieval_case.id}
                    >
                      âœ•
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div
          :if={@selected == nil and @datasets != []}
          class="flex-1 card border border-dashed border-base-300 p-12 text-center"
        >
          <p class="opacity-60 text-sm">Select a dataset to manage documents and test retrieval.</p>
        </div>
      </div>

      <details
        :if={@trashed_datasets != []}
        class="card border border-base-200 p-4"
        id="dataset-trash"
      >
        <summary class="cursor-pointer text-sm font-semibold">
          Trash ({length(@trashed_datasets)}) â€” purged after 30 days
        </summary>

        <div class="mt-2 space-y-2">
          <div
            :for={dataset <- @trashed_datasets}
            class="flex items-center gap-2 text-sm"
            id={"trashed-dataset-#{dataset.id}"}
          >
            <span>{dataset.name}</span>
            <span class="text-xs opacity-50">
              deleted {Calendar.strftime(dataset.deleted_at, "%Y-%m-%d %H:%M")}
            </span>
            <button
              :if={@can_edit}
              class="btn btn-ghost btn-xs ml-auto"
              phx-click="restore_dataset"
              phx-value-dataset-id={dataset.id}
            >
              Restore
            </button>
          </div>
        </div>
      </details>
    </Layouts.console>
    """
  end
end
