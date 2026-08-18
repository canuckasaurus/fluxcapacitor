defmodule Flux.RAG do
  @moduledoc """
  Knowledge pillar: datasets → documents → embedded segments, with hybrid
  retrieval (semantic cosine + Postgres full-text + entity mentions,
  merged by reciprocal rank fusion). Ingestion runs on Oban (`:ingest`
  queue); embeddings go through the workspace's configured provider;
  entity extraction (`Flux.RAG.Entities`) builds the GraphRAG groundwork
  at index time.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope

  alias Flux.RAG.{
    Chunker,
    Dataset,
    Document,
    Entities,
    Entity,
    EntityMention,
    Segment,
    VectorStore
  }

  alias Flux.RBAC
  alias Flux.Repo

  ## Datasets

  def list_datasets(%Scope{} = scope) do
    Dataset
    |> Repo.scoped(scope)
    |> where([d], is_nil(d.deleted_at))
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc "Trashed datasets, newest deletion first (purged after 30 days)."
  def list_trashed_datasets(%Scope{} = scope) do
    Dataset
    |> Repo.scoped(scope)
    |> where([d], not is_nil(d.deleted_at))
    |> order_by([d], desc: d.deleted_at)
    |> Repo.all()
  end

  def restore_dataset(%Scope{} = scope, dataset_id) do
    with :ok <- RBAC.authorize(scope, :dataset_delete),
         %Dataset{} = dataset <-
           Repo.one(Repo.scoped(where(Dataset, id: ^dataset_id), scope)) ||
             {:error, :not_found} do
      dataset |> Ecto.Changeset.change(deleted_at: nil) |> Repo.update()
    end
  end

  @doc "Hard-deletes a trashed dataset now instead of waiting 30 days."
  def purge_dataset(%Scope{} = scope, dataset_id) do
    with :ok <- RBAC.authorize(scope, :dataset_delete),
         %Dataset{deleted_at: %DateTime{}} = dataset <-
           Repo.one(Repo.scoped(where(Dataset, id: ^dataset_id), scope)) ||
             {:error, :not_found},
         {:ok, deleted} <- Repo.delete(dataset) do
      Flux.Audit.record(scope, "dataset.purge",
        resource: dataset,
        metadata: %{"name" => dataset.name}
      )

      {:ok, deleted}
    else
      %Dataset{} -> {:error, :not_trashed}
      error -> error
    end
  end

  def get_dataset(%Scope{} = scope, id) do
    Dataset
    |> where([d], d.id == ^id and is_nil(d.deleted_at))
    |> Repo.scoped(scope)
    |> Repo.one()
    |> Kernel.||({:error, :not_found})
  end

  def create_dataset(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :dataset_create_and_management),
         {:ok, dataset} <-
           %Dataset{workspace_id: Scope.workspace_id(scope)}
           |> Dataset.changeset(attrs)
           |> Repo.insert() do
      Flux.Audit.record(scope, "dataset.create",
        resource: dataset,
        metadata: %{"name" => dataset.name}
      )

      {:ok, dataset}
    end
  end

  @doc "Whether this dataset's retrieval is served by an external endpoint."
  def external?(%Dataset{external_endpoint: endpoint}), do: endpoint not in [nil, ""]

  ## Retrieval feedback (bad citations flagged from the monitor)

  @doc """
  Flags a segment as a bad retrieval — raised from a citation in the
  app monitor, so it only needs the monitor permission. Flagged
  segments queue on the knowledge page for curation.
  """
  def flag_segment(%Scope{} = scope, segment_id, note \\ nil) do
    note = note |> to_string() |> String.trim() |> String.slice(0, 255)

    with :ok <- RBAC.authorize(scope, :app_monitor),
         %Segment{} = segment <-
           Repo.one(Repo.scoped(where(Segment, id: ^segment_id), scope)) ||
             {:error, :not_found} do
      segment
      |> Ecto.Changeset.change(
        flagged_at: DateTime.utc_now(:second),
        flag_note: (note != "" && note) || nil
      )
      |> Repo.update()
    end
  end

  @doc "Clears a segment's retrieval flag (handled, or a false alarm)."
  def unflag_segment(%Scope{} = scope, segment_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Segment{} = segment <-
           Repo.one(Repo.scoped(where(Segment, id: ^segment_id), scope)) ||
             {:error, :not_found} do
      segment
      |> Ecto.Changeset.change(flagged_at: nil, flag_note: nil)
      |> Repo.update()
    end
  end

  @doc "Flagged segments across the workspace, newest first, with their sources."
  def list_flagged_segments(%Scope{} = scope, limit \\ 50) do
    segments =
      Segment
      |> Repo.scoped(scope)
      |> where([s], not is_nil(s.flagged_at))
      |> order_by([s], desc: s.flagged_at)
      |> limit(^limit)
      |> Repo.all()

    # Assoc preloads run unscoped and trip the tenancy guard — load the
    # sources through scoped queries instead.
    document_ids = segments |> Enum.map(& &1.document_id) |> Enum.uniq()

    documents =
      Document
      |> Repo.scoped(scope)
      |> where([d], d.id in ^document_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    dataset_ids = documents |> Map.values() |> Enum.map(& &1.dataset_id) |> Enum.uniq()

    datasets =
      Dataset
      |> Repo.scoped(scope)
      |> where([d], d.id in ^dataset_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(segments, fn segment ->
      document = documents[segment.document_id]
      document = document && %{document | dataset: datasets[document.dataset_id]}
      %{segment | document: document}
    end)
  end

  @doc """
  Registers an external knowledge base as a dataset: retrieval queries
  POST to the user-hosted endpoint (the Dify-compatible `/retrieval`
  contract) and its records come back as ordinary hits — knowledge
  nodes, hit testing, and citations all work unchanged. The API key is
  encrypted with the workspace DEK; the endpoint is SSRF-guarded at
  save time and again on every call. External datasets hold no local
  documents.
  """
  def connect_external_dataset(%Scope{} = scope, attrs) do
    take = fn key -> String.trim(to_string(attrs[key] || attrs[to_string(key)] || "")) end
    name = take.(:name)
    endpoint = take.(:endpoint)
    knowledge_id = take.(:knowledge_id)
    api_key = take.(:api_key)

    with :ok <- RBAC.authorize(scope, :dataset_create_and_management),
         true <- name != "" || {:error, "The dataset needs a name."},
         :ok <- Flux.SSRF.verify_url(endpoint),
         {:ok, encrypted} <- encrypt_external_key(Scope.workspace_id(scope), api_key),
         {:ok, dataset} <-
           %Dataset{workspace_id: Scope.workspace_id(scope)}
           |> Ecto.Changeset.change(
             name: name,
             external_endpoint: endpoint,
             external_knowledge_id: (knowledge_id != "" && knowledge_id) || nil,
             external_api_key: encrypted
           )
           |> Repo.insert() do
      Flux.Audit.record(scope, "dataset.connect_external",
        resource: dataset,
        metadata: %{"name" => name, "endpoint" => endpoint}
      )

      {:ok, dataset}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      other -> other
    end
  end

  defp encrypt_external_key(_workspace_id, ""), do: {:ok, nil}
  defp encrypt_external_key(workspace_id, api_key), do: Flux.Crypto.encrypt(workspace_id, api_key)

  def update_dataset(%Scope{} = scope, %Dataset{} = dataset, attrs) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, updated} <- dataset |> Dataset.changeset(attrs) |> Repo.update() do
      # Auto-sync binds an external source to the dataset — worth a trail.
      if updated.sync_plugin_id != dataset.sync_plugin_id or
           updated.sync_interval_minutes != dataset.sync_interval_minutes do
        Flux.Audit.record(scope, "dataset.auto_sync_config",
          resource: updated,
          metadata: %{
            "sync_plugin_id" => updated.sync_plugin_id,
            "sync_interval_minutes" => updated.sync_interval_minutes
          }
        )
      end

      {:ok, updated}
    end
  end

  @doc """
  Copies the dataset — settings and every document with source text —
  as "<name> (copy)", indexed through the normal pipeline. Sync
  schedules and eval history stay behind: the copy is a sandbox, not a
  second subscriber.
  """
  def duplicate_dataset(%Scope{} = scope, %Dataset{} = dataset) do
    settings =
      dataset
      |> Map.take([
        :description,
        :embedding_plugin_id,
        :embedding_model,
        :chunk_size,
        :chunk_overlap,
        :split_markdown,
        :parent_child,
        :qa_indexing,
        :query_expansion,
        :retrieval_mode,
        :semantic_weight,
        :rerank_plugin_id,
        :rerank_model,
        :retrieval_top_k,
        :score_threshold,
        :entity_plugin_id,
        :entity_model
      ])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("name", "#{dataset.name} (copy)")

    with true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, copy} <- create_dataset(scope, settings) do
      documents =
        Document
        |> Repo.scoped(scope)
        |> where([d], d.dataset_id == ^dataset.id and not is_nil(d.content))
        |> Repo.all()

      for document <- documents do
        {:ok, copied} =
          add_document(scope, copy, %{name: document.name, content: document.content})

        # Tags and metadata travel too (add_document only takes text).
        copied
        |> Ecto.Changeset.change(tags: document.tags, metadata: document.metadata)
        |> Repo.update!()
      end

      {:ok, copy, length(documents)}
    end
  end

  @doc """
  Switches the embedding model and re-embeds everything in one guarded
  move — changing the model piecemeal would leave old and new vectors
  in the same index, silently poisoning similarity.
  """
  def switch_embedding_model(%Scope{} = scope, %Dataset{} = dataset, plugin_id, model)
      when is_binary(plugin_id) and is_binary(model) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, updated} <-
           update_dataset(scope, dataset, %{
             "embedding_plugin_id" => plugin_id,
             "embedding_model" => model
           }),
         {:ok, count} <- reindex_dataset(scope, updated) do
      Flux.Audit.record(scope, "dataset.embedding_switch",
        resource: updated,
        metadata: %{"plugin_id" => plugin_id, "model" => model, "documents" => count}
      )

      {:ok, updated, count}
    end
  end

  @doc "Re-chunks and re-embeds every document that retained its source text."
  def reindex_dataset(%Scope{} = scope, %Dataset{} = dataset) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      documents =
        Document
        |> Repo.scoped(scope)
        |> where([d], d.dataset_id == ^dataset.id and not is_nil(d.content))
        |> Repo.all()

      for document <- documents do
        document |> Ecto.Changeset.change(status: :pending) |> Repo.update!()

        {:ok, _job} =
          %{document_id: document.id}
          |> Flux.RAG.IndexWorker.new()
          |> Oban.insert()
      end

      {:ok, length(documents)}
    end
  end

  @doc "Soft delete: the dataset moves to the trash (30-day purge, restorable)."
  def delete_dataset(%Scope{} = scope, %Dataset{} = dataset) do
    with :ok <- RBAC.authorize(scope, :dataset_delete),
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, trashed} <-
           dataset
           |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
           |> Repo.update() do
      Flux.Audit.record(scope, "dataset.trash", resource: dataset)
      {:ok, trashed}
    end
  end

  ## Documents & ingestion

  @doc """
  Adds a text document and enqueues indexing (extract for files happens
  before this via `Flux.Documents`). Returns the pending document.
  """
  def add_document(scope, dataset, attrs, opts \\ [])

  def add_document(%Scope{} = scope, %Dataset{} = dataset, %{name: name, content: content}, opts)
      when is_binary(content) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         true <- not external?(dataset) || {:error, :external_dataset},
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      # `replace: true` swaps out same-named documents instead of
      # duplicating — re-uploading a file updates the dataset in place.
      # The outgoing content survives as a restorable revision (last five
      # per name).
      if Keyword.get(opts, :replace, false) do
        Document
        |> Repo.scoped(scope)
        |> where([d], d.dataset_id == ^dataset.id and d.name == ^name)
        |> Repo.all()
        |> Enum.each(&retire_document(scope, dataset, &1))
      end

      document =
        Repo.insert!(%Document{
          workspace_id: dataset.workspace_id,
          dataset_id: dataset.id,
          name: name,
          status: :pending,
          content: content
        })

      {:ok, _job} =
        %{document_id: document.id}
        |> Flux.RAG.IndexWorker.new()
        |> Oban.insert()

      {:ok, document}
    end
  end

  @max_fetch_bytes 5_000_000

  @doc """
  Fetches a URL (SSRF-guarded), strips HTML to text, and indexes it as a
  document named after the URL.
  """
  def add_document_from_url(%Scope{} = scope, %Dataset{} = dataset, url) when is_binary(url) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         :ok <- Flux.SSRF.verify_url(url),
         {:ok, %{status: 200, body: body}} <-
           Req.get(
             [
               url: url,
               redirect: false,
               max_retries: 1,
               receive_timeout: 15_000,
               decode_body: false
             ] ++ Application.get_env(:flux_rag, :req_options, [])
           ),
         body = to_string(body),
         :ok <- (byte_size(body) <= @max_fetch_bytes && :ok) || {:error, :too_large} do
      content =
        case Floki.parse_document(body) do
          {:ok, document} ->
            text = document |> Floki.text(sep: " ") |> String.trim()
            if text == "", do: body, else: text

          _not_html ->
            body
        end

      if String.valid?(content) and String.trim(content) != "" do
        uri = URI.parse(url)
        name = String.trim_leading("#{uri.host}#{uri.path}", "/")

        # Refresh runs replace the previous fetch instead of duplicating.
        add_document(scope, dataset, %{name: name, content: content}, replace: true)
      else
        {:error, "the URL did not return readable text"}
      end
    else
      {:ok, %{status: status}} -> {:error, "the URL returned HTTP #{status}"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Ingests a URL plus up to `max_pages - 1` same-host pages it links to
  (depth 1) — enough to pull a docs site in one action without becoming
  a crawler. Every page is SSRF-checked; failures skip, not abort.
  Returns `{:ok, %{added: n, skipped: k}}`.
  """
  def crawl_from_url(%Scope{} = scope, %Dataset{} = dataset, url, max_pages \\ 10)
      when is_binary(url) do
    max_pages = max_pages |> max(1) |> min(25)

    with :ok <- RBAC.authorize(scope, :dataset_edit),
         :ok <- Flux.SSRF.verify_url(url),
         {:ok, %{status: 200, body: body}} <-
           Req.get(
             [
               url: url,
               redirect: false,
               max_retries: 1,
               receive_timeout: 15_000,
               decode_body: false
             ] ++ Application.get_env(:flux_rag, :req_options, [])
           ) do
      links = same_host_links(url, to_string(body)) |> Enum.take(max_pages - 1)

      results =
        for page <- [url | links] do
          case add_document_from_url(scope, dataset, page) do
            {:ok, _document} -> :added
            _failed -> :skipped
          end
        end

      {:ok,
       %{
         added: Enum.count(results, &(&1 == :added)),
         skipped: Enum.count(results, &(&1 == :skipped))
       }}
    else
      {:ok, %{status: status}} -> {:error, "the URL returned HTTP #{status}"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  ## Remembered URL sources (nightly re-fetch)

  @doc "Remembers a URL source so the nightly sweep re-fetches it."
  def remember_url_source(%Scope{} = scope, %Dataset{} = dataset, url, crawl?) do
    with :ok <- RBAC.authorize(scope, :dataset_edit) do
      %Flux.RAG.UrlSource{workspace_id: dataset.workspace_id, dataset_id: dataset.id}
      |> Flux.RAG.UrlSource.changeset(%{"url" => url, "crawl" => crawl?})
      |> Repo.insert(
        on_conflict: {:replace, [:crawl, :updated_at]},
        conflict_target: [:dataset_id, :url]
      )
    end
  end

  def list_url_sources(%Scope{} = scope, dataset_id) do
    Flux.RAG.UrlSource
    |> Repo.scoped(scope)
    |> where([s], s.dataset_id == ^dataset_id)
    |> order_by([s], asc: s.inserted_at)
    |> Repo.all()
  end

  def delete_url_source(%Scope{} = scope, source_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Flux.RAG.UrlSource{} = source <-
           Repo.one(Repo.scoped(where(Flux.RAG.UrlSource, id: ^source_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(source)
    end
  end

  @doc """
  Nightly sweep (03:00 UTC minute tick): re-fetches every remembered
  URL source, replacing same-named documents. Failures skip — a dead
  page never blocks the rest.
  """
  def refresh_url_sources(now \\ DateTime.utc_now(:second)) do
    if now.hour == 3 and now.minute == 0 do
      sources = Repo.all(Flux.RAG.UrlSource, skip_workspace_guard: true)

      for source <- sources do
        scope = url_source_scope(source.workspace_id)

        with %Dataset{} = dataset <- get_dataset(scope, source.dataset_id) do
          if source.crawl do
            crawl_from_url(scope, dataset, source.url)
          else
            add_document_from_url(scope, dataset, source.url)
          end

          source
          |> Ecto.Changeset.change(last_fetched_at: DateTime.utc_now(:second))
          |> Repo.update()
        end
      end

      :ok
    else
      :ok
    end
  end

  @settings_fields ~w(embedding_plugin_id embedding_model chunk_size chunk_overlap
                      split_markdown parent_child query_expansion retrieval_top_k
                      score_threshold)a

  @doc """
  A portable single-dataset archive: settings, documents (content, tags,
  metadata, enabled), golden retrieval cases, and remembered URL
  sources — everything needed to rebuild the dataset elsewhere.
  Embeddings are not exported; the import re-indexes.
  """
  def export_dataset(%Scope{} = scope, dataset_id) do
    with %Dataset{} = dataset <- get_dataset(scope, dataset_id) do
      {:ok,
       %{
         "format" => "flux-dataset/v1",
         "name" => dataset.name,
         "description" => dataset.description,
         "settings" =>
           Map.new(@settings_fields, fn field ->
             {to_string(field), Map.get(dataset, field)}
           end),
         "documents" =>
           for document <- list_documents(scope, dataset.id),
               is_binary(document.content) and document.content != "" do
             %{
               "name" => document.name,
               "content" => document.content,
               "tags" => document.tags,
               "metadata" => document.metadata,
               "enabled" => document.enabled
             }
           end,
         "retrieval_cases" =>
           for retrieval_case <- list_retrieval_cases(scope, dataset.id) do
             %{"question" => retrieval_case.question, "expected" => retrieval_case.expected}
           end,
         "url_sources" =>
           for source <- list_url_sources(scope, dataset.id) do
             %{"url" => source.url, "crawl" => source.crawl}
           end
       }}
    end
  end

  @doc """
  Rebuilds a dataset from an archive map (the export's JSON, decoded).
  Documents queue for indexing; returns `{:ok, dataset, counts}`.
  """
  def import_dataset(%Scope{} = scope, %{"format" => "flux-dataset/v1"} = archive) do
    settings = archive["settings"] || %{}

    attrs =
      settings
      |> Map.take(Enum.map(@settings_fields, &to_string/1))
      |> Map.merge(%{
        "name" => to_string(archive["name"] || "Imported dataset"),
        "description" => archive["description"]
      })

    with {:ok, dataset} <- create_dataset(scope, attrs) do
      documents =
        for %{"name" => name, "content" => content} = document <- archive["documents"] || [],
            is_binary(content) and content != "" do
          {:ok, created} = add_document(scope, dataset, %{name: name, content: content})

          if document["tags"] not in [nil, []],
            do: set_document_tags(scope, created.id, document["tags"])

          if is_map(document["metadata"]) and document["metadata"] != %{},
            do: set_document_metadata(scope, created.id, document["metadata"])

          if document["enabled"] == false, do: set_documents_enabled(scope, [created.id], false)

          created
        end

      cases =
        for %{"question" => question, "expected" => expected} <- archive["retrieval_cases"] || [] do
          {:ok, created} =
            add_retrieval_case(scope, dataset, %{"question" => question, "expected" => expected})

          created
        end

      sources =
        for %{"url" => url} = source <- archive["url_sources"] || [] do
          remember_url_source(scope, dataset, url, source["crawl"] == true)
        end

      {:ok, dataset,
       %{
         documents: length(documents),
         retrieval_cases: length(cases),
         url_sources: length(sources)
       }}
    end
  end

  def import_dataset(%Scope{}, _archive), do: {:error, :unrecognized_archive}

  @doc """
  Re-fetches one remembered URL source immediately (the "fetch now"
  button) — same replace-in-place semantics as the nightly sweep.
  """
  def fetch_url_source_now(%Scope{} = scope, source_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Flux.RAG.UrlSource{} = source <-
           Repo.one(Repo.scoped(where(Flux.RAG.UrlSource, id: ^source_id), scope)) ||
             {:error, :not_found},
         %Dataset{} = dataset <- get_dataset(scope, source.dataset_id) do
      result =
        if source.crawl,
          do: crawl_from_url(scope, dataset, source.url),
          else: add_document_from_url(scope, dataset, source.url)

      source
      |> Ecto.Changeset.change(last_fetched_at: DateTime.utc_now(:second))
      |> Repo.update()

      result
    end
  end

  defp url_source_scope(workspace_id) do
    %Scope{
      workspace: %Flux.Accounts.Workspace{id: workspace_id},
      membership: %Flux.Accounts.Membership{workspace_id: workspace_id, role: :editor}
    }
  end

  # Absolute same-scheme+host links from the page, fragments stripped,
  # the page itself excluded, first-appearance order.
  defp same_host_links(base_url, html) do
    base = URI.parse(base_url)

    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.attribute("a", "href")
        |> Enum.map(fn href ->
          base |> URI.merge(String.trim(href)) |> Map.put(:fragment, nil) |> URI.to_string()
        end)
        |> Enum.filter(fn link ->
          uri = URI.parse(link)
          uri.scheme in ["http", "https"] and uri.host == base.host and link != base_url
        end)
        |> Enum.uniq()

      _not_html ->
        []
    end
  end

  @doc """
  Starts a background sync of an installed datasource plugin into the
  dataset: every document the source offers that the dataset doesn't
  already hold (by name) is fetched and indexed.
  """
  def sync_datasource(%Scope{} = scope, %Dataset{} = dataset, plugin_id) do
    with :ok <- Flux.Features.authorize(scope, :datasource_sync),
         :ok <- RBAC.authorize(scope, :dataset_edit),
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         true <-
           Flux.Tools.plugin_installed?(dataset.workspace_id, plugin_id) ||
             {:error, :plugin_not_installed},
         {:ok, job} <-
           %{dataset_id: dataset.id, plugin_id: plugin_id}
           |> Flux.RAG.DatasourceSyncWorker.new()
           |> Oban.insert() do
      Flux.Audit.record(scope, "dataset.sync",
        resource: dataset,
        metadata: %{"plugin_id" => plugin_id}
      )

      {:ok, job}
    end
  end

  @doc false
  # The sync body, called by DatasourceSyncWorker: list what the source
  # offers, skip names already in the dataset, fetch + index the rest.
  # A vanished dataset is a no-op (deleted between enqueue and run).
  def sync_dataset_from_datasource(dataset_id, plugin_id) do
    case Repo.get(Dataset, dataset_id, skip_workspace_guard: true) do
      nil ->
        {:ok, 0}

      dataset ->
        credentials =
          case Flux.Providers.fetch_config(dataset.workspace_id, plugin_id) do
            {:ok, config} -> config
            {:error, :not_configured} -> %{}
          end

        with {:ok, offered} <- plugin_runtime().datasource_documents(plugin_id, credentials) do
          existing =
            Document
            |> where([d], d.dataset_id == ^dataset.id)
            |> select([d], d.name)
            |> Repo.all(skip_workspace_guard: true)
            |> MapSet.new()

          added =
            for source_doc <- offered, not MapSet.member?(existing, source_doc.name) do
              case plugin_runtime().fetch_datasource_document(
                     plugin_id,
                     credentials,
                     source_doc.id
                   ) do
                {:ok, %{content: content}} when is_binary(content) and content != "" ->
                  document =
                    Repo.insert!(%Document{
                      workspace_id: dataset.workspace_id,
                      dataset_id: dataset.id,
                      name: source_doc.name,
                      status: :pending,
                      content: content
                    })

                  {:ok, _job} =
                    %{document_id: document.id}
                    |> Flux.RAG.IndexWorker.new()
                    |> Oban.insert()

                  1

                _empty_or_error ->
                  0
              end
            end

          count = Enum.sum(added)

          Flux.Webhooks.dispatch(dataset.workspace_id, "dataset.synced", %{
            "dataset_id" => dataset.id,
            "name" => dataset.name,
            "plugin_id" => plugin_id,
            "documents_added" => count
          })

          {:ok, count}
        end
    end
  end

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  def list_documents(%Scope{} = scope, dataset_id) do
    Document
    |> Repo.scoped(scope)
    |> where([d], d.dataset_id == ^dataset_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Replaces a document's content by id and re-indexes — the API's
  update-by-text. The outgoing content is kept as a revision, same as
  replace-mode uploads.
  """
  def update_document_text(%Scope{} = scope, document_id, text, name \\ nil)
      when is_binary(text) and text != "" do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Document{} = document <-
           Repo.one(Repo.scoped(where(Document, id: ^document_id), scope)) ||
             {:error, :not_found} do
      if is_binary(document.content) and document.content != "" do
        Repo.insert!(%Flux.RAG.DocumentRevision{
          workspace_id: document.workspace_id,
          dataset_id: document.dataset_id,
          name: document.name,
          content: document.content
        })

        prune_revisions(scope, document.dataset_id, document.name)
      end

      {:ok, updated} =
        document
        |> Ecto.Changeset.change(
          content: text,
          name: (is_binary(name) and name != "" && name) || document.name,
          status: :pending
        )
        |> Repo.update()

      {:ok, _job} =
        %{document_id: updated.id}
        |> Flux.RAG.IndexWorker.new()
        |> Oban.insert()

      {:ok, updated}
    end
  end

  @doc "Fetches one document for original-content download (its own permission)."
  def download_document(%Scope{} = scope, document_id) do
    with :ok <- RBAC.authorize(scope, :dataset_document_download),
         %Document{} = document <-
           Repo.one(Repo.scoped(where(Document, id: ^document_id), scope)) ||
             {:error, :not_found} do
      {:ok, document}
    end
  end

  def delete_document(%Scope{} = scope, document_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Document{} = document <-
           Repo.one(Repo.scoped(where(Document, id: ^document_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(document)
    end
  end

  @doc """
  Case-insensitive content search across a dataset's segments (the
  knowledge browser's search box). Returns `%{segment, document_id,
  document_name}` rows, document order then position.
  """
  def search_dataset(%Scope{} = scope, dataset_id, q, limit \\ 20) do
    case String.trim(to_string(q)) do
      "" ->
        []

      trimmed ->
        pattern = "%" <> String.replace(trimmed, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

        Segment
        |> Repo.scoped(scope)
        |> where([s], s.dataset_id == ^dataset_id and ilike(s.content, ^pattern))
        |> join(:inner, [s], d in Document, on: s.document_id == d.id)
        |> order_by([s, d], asc: d.name, asc: s.position)
        |> limit(^limit)
        |> select([s, d], %{segment: s, document_id: d.id, document_name: d.name})
        |> Repo.all()
    end
  end

  ## Bulk document operations (multi-select in the dataset browser)

  @doc """
  Enables or disables several documents at once. The flag cascades to
  their segments, which is what retrieval actually filters on — content
  stays indexed and flips back losslessly.
  """
  def set_documents_enabled(%Scope{} = scope, document_ids, enabled)
      when is_list(document_ids) and is_boolean(enabled) do
    with :ok <- RBAC.authorize(scope, :dataset_edit) do
      {count, _} =
        Document
        |> Repo.scoped(scope)
        |> where([d], d.id in ^document_ids)
        |> Repo.update_all(set: [enabled: enabled])

      Segment
      |> Repo.scoped(scope)
      |> where([s], s.document_id in ^document_ids)
      |> Repo.update_all(set: [enabled: enabled])

      {:ok, count}
    end
  end

  @doc "A replaced name's prior contents, newest first."
  def list_document_revisions(%Scope{} = scope, dataset_id, name) do
    Flux.RAG.DocumentRevision
    |> Repo.scoped(scope)
    |> where([r], r.dataset_id == ^dataset_id and r.name == ^name)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
  end

  @doc """
  Restores a revision as the current document (replace-mode, so today's
  content becomes the newest revision — restore is never destructive).
  """
  def restore_document_revision(%Scope{} = scope, revision_id) do
    with %Flux.RAG.DocumentRevision{} = revision <-
           Repo.one(Repo.scoped(where(Flux.RAG.DocumentRevision, id: ^revision_id), scope)) ||
             {:error, :not_found},
         %Dataset{} = dataset <- get_dataset(scope, revision.dataset_id) do
      add_document(scope, dataset, %{name: revision.name, content: revision.content},
        replace: true
      )
    end
  end

  # Replace-mode retirement: the outgoing content becomes a revision
  # (last five per name), then the row goes.
  defp retire_document(scope, dataset, old_document) do
    if is_binary(old_document.content) and old_document.content != "" do
      Repo.insert!(%Flux.RAG.DocumentRevision{
        workspace_id: old_document.workspace_id,
        dataset_id: dataset.id,
        name: old_document.name,
        content: old_document.content
      })

      prune_revisions(scope, dataset.id, old_document.name)
    end

    Repo.delete(old_document)
  end

  defp prune_revisions(scope, dataset_id, name) do
    keep =
      Flux.RAG.DocumentRevision
      |> Repo.scoped(scope)
      |> where([r], r.dataset_id == ^dataset_id and r.name == ^name)
      |> order_by([r], desc: r.inserted_at, desc: r.id)
      |> limit(5)
      |> select([r], r.id)
      |> Repo.all()

    Flux.RAG.DocumentRevision
    |> Repo.scoped(scope)
    |> where([r], r.dataset_id == ^dataset_id and r.name == ^name and r.id not in ^keep)
    |> Repo.delete_all()
  end

  @doc "Sets (or with nil, clears) a document's expiry date."
  def set_document_expiry(%Scope{} = scope, document_id, expires_at)
      when is_nil(expires_at) or is_struct(expires_at, DateTime) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Document{} = document <-
           Repo.one(Repo.scoped(where(Document, id: ^document_id), scope)) ||
             {:error, :not_found} do
      document |> Ecto.Changeset.change(expires_at: expires_at) |> Repo.update()
    end
  end

  @doc """
  Nightly tick: documents past their expiry disable (segments cascade,
  so they drop out of retrieval) — re-enabling manually also clears the
  expiry, deliberately: waking expired content is a decision, not a
  default.
  """
  def disable_expired_documents(now \\ DateTime.utc_now(:second)) do
    expired =
      Document
      |> where([d], not is_nil(d.expires_at) and d.expires_at <= ^now and d.enabled)
      |> select([d], d.id)
      |> Repo.all(skip_workspace_guard: true)

    if expired != [] do
      from(d in Document, where: d.id in ^expired)
      |> Repo.update_all([set: [enabled: false]], skip_workspace_guard: true)

      from(s in Segment, where: s.document_id in ^expired)
      |> Repo.update_all([set: [enabled: false]], skip_workspace_guard: true)
    end

    {:ok, length(expired)}
  end

  @doc "Deletes several documents at once (segments cascade)."
  def delete_documents(%Scope{} = scope, document_ids) when is_list(document_ids) do
    with :ok <- RBAC.authorize(scope, :dataset_edit) do
      {count, _} =
        Document
        |> Repo.scoped(scope)
        |> where([d], d.id in ^document_ids)
        |> Repo.delete_all()

      {:ok, count}
    end
  end

  @doc "Adds tags to several documents at once (merged with existing, deduped)."
  def tag_documents(%Scope{} = scope, document_ids, tags)
      when is_list(document_ids) and is_list(tags) do
    with :ok <- RBAC.authorize(scope, :dataset_edit) do
      normalized =
        tags
        |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      documents =
        Document
        |> Repo.scoped(scope)
        |> where([d], d.id in ^document_ids)
        |> Repo.all()

      for document <- documents do
        document
        |> Ecto.Changeset.change(tags: Enum.uniq(document.tags ++ normalized))
        |> Repo.update!()
      end

      {:ok, length(documents)}
    end
  end

  def list_segments(%Scope{} = scope, document_id, limit \\ 100) do
    Segment
    |> Repo.scoped(scope)
    |> where([s], s.document_id == ^document_id)
    |> order_by([s], asc: s.position)
    |> limit(^limit)
    |> Repo.all()
  end

  ## Segment editing

  @doc "Rewrites one segment's text and re-embeds it in place."
  def update_segment(%Scope{} = scope, segment_id, content) when is_binary(content) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Segment{} = segment <- fetch_segment(scope, segment_id),
         true <- String.trim(content) != "" || {:error, :empty},
         dataset = Repo.get!(Dataset, segment.dataset_id, skip_workspace_guard: true),
         {:ok, [vector]} <- embed(dataset, [content]) do
      updated =
        segment
        |> Ecto.Changeset.change(content: content, embedding: vector)
        |> Repo.update!()

      :ok = VectorStore.backend().index(dataset.id, [updated])

      Flux.Audit.record(scope, "segment.update",
        resource_type: "segment",
        resource_id: segment.id,
        metadata: %{"dataset_id" => segment.dataset_id}
      )

      {:ok, updated}
    end
  end

  @doc "Disabled segments stay stored but are excluded from retrieval."
  def set_segment_enabled(%Scope{} = scope, segment_id, enabled) when is_boolean(enabled) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Segment{} = segment <- fetch_segment(scope, segment_id),
         {:ok, updated} <- segment |> Ecto.Changeset.change(enabled: enabled) |> Repo.update() do
      Flux.Audit.record(scope, "segment.set_enabled",
        resource_type: "segment",
        resource_id: segment.id,
        metadata: %{"dataset_id" => segment.dataset_id, "enabled" => enabled}
      )

      {:ok, updated}
    end
  end

  def delete_segment(%Scope{} = scope, segment_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Segment{} = segment <- fetch_segment(scope, segment_id),
         {:ok, deleted} <- Repo.delete(segment) do
      from(d in Document, where: d.id == ^segment.document_id)
      |> Repo.update_all([inc: [segment_count: -1]], skip_workspace_guard: true)

      Flux.Audit.record(scope, "segment.delete",
        resource_type: "segment",
        resource_id: segment.id,
        metadata: %{"dataset_id" => segment.dataset_id}
      )

      {:ok, deleted}
    end
  end

  defp fetch_segment(scope, segment_id) do
    Repo.one(Repo.scoped(where(Segment, id: ^segment_id), scope)) || {:error, :not_found}
  end

  @doc false
  # The ingestion body, called by IndexWorker (and directly by tests):
  # clear old segments → split (dataset chunk settings) → embed →
  # insert → flip status. Idempotent, so re-index just re-runs it.
  def index_document(document_id) do
    document = Repo.get!(Document, document_id, skip_workspace_guard: true)
    dataset = Repo.get!(Dataset, document.dataset_id, skip_workspace_guard: true)

    document |> Ecto.Changeset.change(status: :indexing) |> Repo.update!()

    {_count, nil} =
      from(s in Segment, where: s.document_id == ^document.id)
      |> Repo.delete_all(skip_workspace_guard: true)

    chunk_opts = [
      max_chars: dataset.chunk_size || 1000,
      overlap: dataset.chunk_overlap || 120,
      markdown: dataset.split_markdown || false
    ]

    # Parent-child datasets embed small children; each remembers the
    # enclosing parent section retrieval will hand to the model.
    pairs =
      if dataset.parent_child do
        Chunker.split_parent_child(document.content || "", chunk_opts)
      else
        for chunk <- Chunker.split(document.content || "", chunk_opts), do: {chunk, nil}
      end

    # Q&A indexing rides the same parent-promotion rails: each chunk
    # becomes one segment per generated question, with the original
    # passage as parent_content. A chunk whose generation comes back
    # empty stays as itself — indexing must not lose content.
    pairs = if dataset.qa_indexing, do: qa_pairs(document.workspace_id, pairs), else: pairs

    case embed(dataset, Enum.map(pairs, fn {chunk, _parent} -> chunk end)) do
      {:ok, vectors} ->
        segments =
          for {{{chunk, parent}, vector}, position} <- Enum.with_index(Enum.zip(pairs, vectors)) do
            Repo.insert!(%Segment{
              workspace_id: document.workspace_id,
              dataset_id: dataset.id,
              document_id: document.id,
              position: position,
              content: chunk,
              parent_content: parent,
              embedding: vector,
              # Re-indexing a disabled document must not silently re-enable it.
              enabled: document.enabled
            })
          end

        :ok = VectorStore.backend().index(dataset.id, segments)
        index_entities(dataset, segments)

        # Rough tokens-embedded meter (chars/4): embedding spend was
        # invisible next to the LLM meters.
        embedded_estimate =
          pairs
          |> Enum.map(fn {chunk, _parent} -> div(byte_size(chunk), 4) + 1 end)
          |> Enum.sum()

        from(d in Dataset, where: d.id == ^dataset.id)
        |> Repo.update_all([inc: [embedded_tokens: embedded_estimate]],
          skip_workspace_guard: true
        )

        document
        |> Ecto.Changeset.change(status: :ready, segment_count: length(segments), error: nil)
        |> Repo.update!()

        Flux.Webhooks.dispatch(document.workspace_id, "document.indexed", %{
          "document_id" => document.id,
          "name" => document.name,
          "dataset_id" => dataset.id,
          "segments" => length(segments)
        })

        :ok

      {:error, reason} ->
        document
        |> Ecto.Changeset.change(status: :error, error: format_error(reason))
        |> Repo.update!()

        Flux.Webhooks.dispatch(document.workspace_id, "document.failed", %{
          "document_id" => document.id,
          "name" => document.name,
          "dataset_id" => dataset.id,
          "error" => format_error(reason)
        })

        {:error, reason}
    end
  end

  # Q&A transform: up to three model-written questions per chunk, each
  # becoming a {question, passage} pair. Best-effort per chunk — a
  # failed or empty generation keeps the original pair. Tests inject
  # `config :flux, :qa_generator`.
  defp qa_pairs(workspace_id, pairs) do
    generator =
      Application.get_env(:flux, :qa_generator) ||
        fn chunk ->
          prompt = """
          Write up to three standalone questions this passage answers —
          questions a user might actually type. One per line, nothing else.

          Passage:
          #{String.slice(chunk, 0, 6_000)}
          """

          case Flux.Workflows.invoke_default_llm_for_workspace(workspace_id, [
                 %{role: :user, content: prompt}
               ]) do
            {:ok, content} when is_binary(content) ->
              content
              |> String.split(~r/\r?\n/, trim: true)
              |> Enum.map(&String.trim(String.trim(&1), "- "))
              |> Enum.reject(&(&1 == "" or String.length(&1) > 500))
              |> Enum.take(3)

            _error_or_no_model ->
              []
          end
        end

    Enum.flat_map(pairs, fn {chunk, parent} ->
      case generator.(chunk) do
        [] -> [{chunk, parent}]
        questions -> for question <- questions, do: {question, parent || chunk}
      end
    end)
  end

  # GraphRAG groundwork: every segment's extracted entities land in
  # rag_entities/rag_entity_mentions (old mentions died with the old
  # segments via FK cascade). See Flux.RAG.Entities.
  defp index_entities(dataset, segments) do
    names_by_segment =
      for segment <- segments,
          names = extract_entities(dataset, segment.content),
          names != [],
          do: {segment, names}

    all_names =
      names_by_segment |> Enum.flat_map(fn {_segment, names} -> names end) |> Enum.uniq()

    if all_names != [] do
      now = DateTime.utc_now(:second)

      Repo.insert_all(
        Entity,
        for name <- all_names do
          %{
            id: UUIDv7.generate(),
            workspace_id: dataset.workspace_id,
            dataset_id: dataset.id,
            name: name,
            inserted_at: now
          }
        end,
        on_conflict: :nothing
      )

      entity_ids =
        Entity
        |> where([e], e.dataset_id == ^dataset.id and e.name in ^all_names)
        |> select([e], {e.name, e.id})
        |> Repo.all(skip_workspace_guard: true)
        |> Map.new()

      mentions =
        for {segment, names} <- names_by_segment,
            name <- names,
            entity_id = entity_ids[name],
            entity_id != nil do
          %{
            id: UUIDv7.generate(),
            workspace_id: dataset.workspace_id,
            dataset_id: dataset.id,
            entity_id: entity_id,
            segment_id: segment.id
          }
        end

      Repo.insert_all(EntityMention, mentions, on_conflict: :nothing)
    end

    sync_entity_graph(dataset)

    :ok
  end

  # Best-effort mirror of the dataset's co-occurrence graph into Arango
  # (Postgres stays the system of record). Never fails indexing.
  defp sync_entity_graph(dataset) do
    if Flux.RAG.ArangoGraph.configured?() do
      rows =
        EntityMention
        |> join(:inner, [m], e in Entity, on: m.entity_id == e.id)
        |> where([m], m.dataset_id == ^dataset.id)
        |> select([m, e], {m.segment_id, e.name})
        |> Repo.all(skip_workspace_guard: true)

      entities = rows |> Enum.map(fn {_segment, name} -> %{name: name} end) |> Enum.uniq()

      pairs =
        rows
        |> Enum.group_by(fn {segment_id, _name} -> segment_id end, fn {_segment, name} ->
          name
        end)
        |> Enum.flat_map(fn {_segment, names} ->
          names = Enum.uniq(names)
          for a <- names, b <- names, a < b, do: {a, b}
        end)
        |> Enum.frequencies()

      case Flux.RAG.ArangoGraph.sync_dataset(dataset.id, entities, pairs) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end

    :ok
  end

  # Datasets can bind a chat model for extraction quality; the heuristic
  # stays the default and the fallback on any model error, so indexing
  # never fails because of the extractor.
  defp extract_entities(
         %Dataset{entity_plugin_id: plugin_id, entity_model: model} = dataset,
         content
       )
       when is_binary(plugin_id) and plugin_id != "" and is_binary(model) and model != "" do
    with true <-
           Flux.Features.enabled_for_workspace?(dataset.workspace_id, :llm_entity_extraction),
         {:ok, names} <- llm_extract(dataset, content) do
      names
    else
      # Plan-gated or model error: the heuristic still indexes.
      _fallback -> Entities.extract(content)
    end
  end

  defp extract_entities(_dataset, content), do: Entities.extract(content)

  defp llm_extract(dataset, content) do
    credentials =
      case Flux.Providers.fetch_config(dataset.workspace_id, dataset.entity_plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    request = %Flux.Plugin.ModelProvider.Request{
      model: dataset.entity_model,
      messages: [
        %{
          role: :system,
          content:
            "Extract the named entities (people, organizations, products, " <>
              "places, technologies) mentioned in the user's text. Respond " <>
              "with ONLY a JSON array of entity name strings."
        },
        %{role: :user, content: String.slice(content, 0, 6_000)}
      ]
    }

    with {:ok, %{content: reply}} <-
           plugin_runtime().invoke_llm(
             dataset.entity_plugin_id,
             credentials,
             request,
             fn _chunk -> :ok end
           ),
         {:ok, names} when is_list(names) <- Jason.decode(first_json_array(reply)) do
      {:ok,
       names
       |> Enum.filter(&is_binary/1)
       |> Enum.map(&Entities.normalize/1)
       |> Enum.reject(&(&1 == ""))
       |> Enum.uniq()
       |> Enum.take(50)}
    else
      _error_or_invalid -> :error
    end
  end

  # Models love prose and code fences around the array; take the array.
  defp first_json_array(reply) do
    case Regex.run(~r/\[.*\]/s, reply || "") do
      [json] -> json
      nil -> reply || ""
    end
  end

  @doc "Entities known in a dataset with their mention counts, most-mentioned first."
  def list_entities(%Scope{} = scope, dataset_id, limit \\ 50) do
    EntityMention
    |> Repo.scoped(scope)
    |> join(:inner, [m], e in Entity, on: m.entity_id == e.id)
    |> where([m], m.dataset_id == ^dataset_id)
    |> group_by([m, e], e.name)
    |> order_by([m, e], desc: count(m.id), asc: e.name)
    |> limit(^limit)
    |> select([m, e], %{name: e.name, mentions: count(m.id)})
    |> Repo.all()
  end

  @doc """
  Entities co-occurring with the named one (shared segments), strongest
  first — the graph-traversal seed an Arango backend will deepen.
  """
  def related_entities(%Scope{} = scope, dataset_id, name, limit \\ 10) do
    normalized = Entities.normalize(name)

    with true <- Flux.RAG.ArangoGraph.configured?(),
         {:ok, related} when related != [] <-
           Flux.RAG.ArangoGraph.related(dataset_id, normalized, limit) do
      for entry <- related, do: %{name: entry.name, shared_segments: round(entry.weight || 0)}
    else
      _unconfigured_or_error -> related_entities_sql(scope, dataset_id, normalized, limit)
    end
  end

  defp related_entities_sql(scope, dataset_id, normalized, limit) do
    EntityMention
    |> Repo.scoped(scope)
    |> join(:inner, [m], e in Entity, on: m.entity_id == e.id)
    |> join(:inner, [m], m2 in EntityMention,
      on: m2.segment_id == m.segment_id and m2.entity_id != m.entity_id
    )
    |> join(:inner, [m, e, m2], e2 in Entity, on: m2.entity_id == e2.id)
    |> where([m, e], m.dataset_id == ^dataset_id and e.name == ^normalized)
    |> group_by([m, e, m2, e2], e2.name)
    |> order_by([m, e, m2, e2], desc: count(m.id), asc: e2.name)
    |> limit(^limit)
    |> select([m, e, m2, e2], %{name: e2.name, shared_segments: count(m.id)})
    |> Repo.all()
  end

  @doc "Sets a document's tags (comma-splittable metadata for retrieval filters)."
  def set_document_tags(%Scope{} = scope, document_id, tags) when is_list(tags) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Document{} = document <-
           Repo.one(Repo.scoped(where(Document, id: ^document_id), scope)) ||
             {:error, :not_found} do
      normalized =
        tags
        |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      document |> Ecto.Changeset.change(tags: normalized) |> Repo.update()
    end
  end

  @doc "Sets a document's metadata map (string keys/values; blank values drop)."
  def set_document_metadata(%Scope{} = scope, document_id, metadata) when is_map(metadata) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Document{} = document <-
           Repo.one(Repo.scoped(where(Document, id: ^document_id), scope)) ||
             {:error, :not_found} do
      normalized =
        metadata
        |> Enum.map(fn {key, value} ->
          {String.trim(to_string(key)), String.trim(to_string(value))}
        end)
        |> Enum.reject(fn {key, value} -> key == "" or value == "" end)
        |> Map.new()

      document |> Ecto.Changeset.change(metadata: normalized) |> Repo.update()
    end
  end

  ## Retrieval evals (golden question → expected-passage cases)

  def add_retrieval_case(%Scope{} = scope, %Dataset{} = dataset, attrs) do
    with :ok <- RBAC.authorize(scope, :dataset_edit) do
      %Flux.RAG.RetrievalCase{workspace_id: dataset.workspace_id, dataset_id: dataset.id}
      |> Flux.RAG.RetrievalCase.changeset(attrs)
      |> Repo.insert()
    end
  end

  def list_retrieval_cases(%Scope{} = scope, dataset_id) do
    Flux.RAG.RetrievalCase
    |> Repo.scoped(scope)
    |> where([c], c.dataset_id == ^dataset_id)
    |> order_by([c], asc: c.inserted_at)
    |> Repo.all()
  end

  def delete_retrieval_case(%Scope{} = scope, case_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Flux.RAG.RetrievalCase{} = retrieval_case <-
           Repo.one(Repo.scoped(where(Flux.RAG.RetrievalCase, id: ^case_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(retrieval_case)
    end
  end

  @doc """
  Scores retrieval against the dataset's golden cases: for each, the
  rank of the first returned passage containing `expected`
  (case-insensitive). Returns `%{total, hits, hit_rate, mrr, results}` —
  hit rate says how often the answer came back at all, MRR how high.
  """
  def evaluate_retrieval(%Scope{} = scope, dataset_id) do
    cases = list_retrieval_cases(scope, dataset_id)

    results =
      for retrieval_case <- cases do
        rank =
          case retrieve(scope, dataset_id, retrieval_case.question) do
            {:ok, hits} ->
              needle = String.downcase(retrieval_case.expected)

              hits
              |> Enum.find_index(&String.contains?(String.downcase(&1.content), needle))
              |> then(&(&1 && &1 + 1))

            _error ->
              nil
          end

        %{
          case_id: retrieval_case.id,
          question: retrieval_case.question,
          expected: retrieval_case.expected,
          rank: rank
        }
      end

    hits = Enum.count(results, & &1.rank)
    ranks = for %{rank: rank} <- results, rank, do: 1 / rank

    %{
      total: length(results),
      hits: hits,
      hit_rate: (results != [] && Float.round(hits / length(results), 4)) || nil,
      mrr: (results != [] && Float.round(Enum.sum(ranks) / length(results), 4)) || nil,
      results: results
    }
  end

  @doc """
  Minute tick (via the schedule worker): runs `evaluate_retrieval/2` for
  every dataset whose `retrieval_eval_cron` matches this minute, stores
  the scores, and raises an `eval_regressed` notification when hit rate
  or MRR fell below the previous run.
  """
  def run_scheduled_retrieval_evals(now \\ DateTime.utc_now(:second)) do
    minute_start = %{now | second: 0}

    datasets =
      Repo.all(
        where(Dataset, [d], not is_nil(d.retrieval_eval_cron) and is_nil(d.deleted_at)),
        skip_workspace_guard: true
      )

    for dataset <- datasets,
        cron_due?(dataset.retrieval_eval_cron, now),
        is_nil(dataset.last_retrieval_eval_at) or
          DateTime.compare(dataset.last_retrieval_eval_at, minute_start) == :lt do
      scope = url_source_scope(dataset.workspace_id)
      report = evaluate_retrieval(scope, dataset.id)

      if is_number(report.hit_rate) do
        maybe_notify_retrieval_regression(dataset, report)
      end

      dataset
      |> Ecto.Changeset.change(
        last_retrieval_hit_rate: report.hit_rate,
        last_retrieval_mrr: report.mrr,
        last_retrieval_eval_at: DateTime.utc_now(:second)
      )
      |> Repo.update()
    end

    :ok
  end

  defp maybe_notify_retrieval_regression(dataset, report) do
    regressed =
      (is_number(dataset.last_retrieval_hit_rate) and
         report.hit_rate < dataset.last_retrieval_hit_rate) or
        (is_number(dataset.last_retrieval_mrr) and is_number(report.mrr) and
           report.mrr < dataset.last_retrieval_mrr)

    if regressed do
      Flux.Notifications.notify(
        dataset.workspace_id,
        "eval_regressed",
        "Retrieval on \"#{dataset.name}\" regressed: hit rate " <>
          "#{dataset.last_retrieval_hit_rate} → #{report.hit_rate}, MRR " <>
          "#{dataset.last_retrieval_mrr} → #{report.mrr}",
        "/console/knowledge/#{dataset.id}"
      )
    end
  end

  defp cron_due?(cron, now) do
    case Oban.Cron.Expression.parse(cron) do
      {:ok, expression} -> Oban.Cron.Expression.now?(expression, now)
      {:error, _reason} -> false
    end
  end

  defp embed(_dataset, []), do: {:ok, []}

  defp embed(dataset, chunks) do
    Flux.Providers.embed_texts(
      dataset.workspace_id,
      dataset.embedding_plugin_id,
      dataset.embedding_model,
      chunks
    )
  end

  ## Retrieval

  @rrf_k 60

  @doc """
  Hybrid retrieval: semantic (vector store) and keyword (Postgres
  full-text) rankings merged by reciprocal rank fusion. Returns segments
  with `:score` and preloaded document names, best first.

  `top_k` falls back to the dataset's `retrieval_top_k` (then 4); a
  dataset `score_threshold` drops hits whose final score (RRF fusion, or
  the rerank score when a reranker is configured) falls below it.
  """
  def retrieve(%Scope{} = scope, dataset_id, query, opts \\ []) do
    with %Dataset{} = dataset <- get_dataset(scope, dataset_id) do
      if external?(dataset),
        do: external_retrieve(dataset, query, opts),
        else: local_retrieve(scope, dataset, query, opts)
    end
  end

  # External datasets never touch the local index: the query goes to the
  # registered endpoint and its records come back shaped like hits
  # (content/score/document.name), so every consumer works unchanged.
  defp external_retrieve(%Dataset{} = dataset, query, opts) do
    top_k = Keyword.get(opts, :top_k) || dataset.retrieval_top_k || 4

    payload = %{
      "knowledge_id" => dataset.external_knowledge_id,
      "query" => query,
      "retrieval_setting" => %{
        "top_k" => top_k,
        "score_threshold" => dataset.score_threshold || 0.0
      }
    }

    headers =
      case decrypt_external_key(dataset) do
        nil -> []
        api_key -> [{"authorization", "Bearer " <> api_key}]
      end

    with :ok <- Flux.SSRF.verify_url(dataset.external_endpoint),
         {:ok, %{status: 200, body: %{"records" => records}}} when is_list(records) <-
           Req.post(
             [
               url: dataset.external_endpoint,
               json: payload,
               headers: headers,
               redirect: false,
               max_retries: 1,
               receive_timeout: 15_000
             ] ++ Application.get_env(:flux_rag, :req_options, [])
           ) do
      hits =
        records
        |> Enum.take(top_k)
        |> Enum.map(&external_hit(&1, dataset))
        |> Enum.reject(&(&1.content == ""))

      {:ok, hits}
    else
      {:ok, %{status: 200}} ->
        {:error, "the external knowledge endpoint returned no records"}

      {:ok, %{status: status}} ->
        {:error, "the external knowledge endpoint returned HTTP #{status}"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp external_hit(record, dataset) when is_map(record) do
    title =
      case String.trim(to_string(record["title"] || "")) do
        "" -> dataset.name
        title -> title
      end

    %{
      id: nil,
      document_id: nil,
      content: String.trim(to_string(record["content"] || "")),
      score: (is_number(record["score"]) && record["score"] * 1.0) || 0.0,
      document: %{name: title},
      metadata: (is_map(record["metadata"]) && record["metadata"]) || %{}
    }
  end

  defp external_hit(_malformed, dataset),
    do: %{
      id: nil,
      document_id: nil,
      content: "",
      score: 0.0,
      document: %{name: dataset.name},
      metadata: %{}
    }

  defp decrypt_external_key(%Dataset{external_api_key: nil}), do: nil

  defp decrypt_external_key(%Dataset{} = dataset) do
    case Flux.Crypto.decrypt(dataset.workspace_id, dataset.external_api_key) do
      {:ok, api_key} -> api_key
      _undecryptable -> nil
    end
  end

  defp local_retrieve(%Scope{} = scope, %Dataset{id: dataset_id} = dataset, query, opts) do
    top_k = Keyword.get(opts, :top_k) || dataset.retrieval_top_k || 4
    rerank? = dataset.rerank_plugin_id not in [nil, ""]
    candidates = if rerank?, do: top_k * 3, else: top_k

    # Query expansion (per-dataset opt-in): alternate phrasings each
    # contribute their own rankings to the RRF fusion.
    queries = [query | expand_query(scope, dataset, query)]

    # Retrieval mode picks the sources; each ranking carries the
    # weight its RRF contributions are scaled by. In hybrid mode
    # `semantic_weight` skews the fusion (×2w semantic, ×2(1−w)
    # keyword/entity — 0.5 or nil is plain RRF); single-source modes
    # are always unweighted.
    {semantic_scale, lexical_scale} =
      case dataset.semantic_weight do
        weight when is_float(weight) -> {2 * weight, 2 * (1.0 - weight)}
        _neutral -> {1.0, 1.0}
      end

    rankings =
      Enum.flat_map(queries, fn variant ->
        case dataset.retrieval_mode do
          :semantic ->
            [{semantic_hits(dataset, variant, top_k * 3), 1.0}]

          :keyword ->
            [
              {keyword_hits(scope, dataset_id, variant, top_k * 3), 1.0},
              {entity_hits(scope, dataset_id, variant, top_k * 3), 1.0}
            ]

          _hybrid ->
            [
              {semantic_hits(dataset, variant, top_k * 3), semantic_scale},
              {keyword_hits(scope, dataset_id, variant, top_k * 3), lexical_scale},
              {entity_hits(scope, dataset_id, variant, top_k * 3), lexical_scale}
            ]
        end
      end)

    ranked =
      rankings
      |> Enum.reduce(%{}, fn {hits, scale}, acc ->
        hits
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {segment_id, rank}, acc ->
          contribution = scale / (@rrf_k + rank)
          Map.update(acc, segment_id, contribution, &(&1 + contribution))
        end)
      end)
      |> Enum.sort_by(fn {_segment_id, score} -> score end, :desc)
      |> Enum.take(candidates)

    ids = Enum.map(ranked, fn {segment_id, _score} -> segment_id end)
    scores = Map.new(ranked)
    tags = opts |> Keyword.get(:tags, []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    metadata_filter = Keyword.get(opts, :metadata, %{})

    segments =
      Segment
      |> Repo.scoped(scope)
      |> where([s], s.id in ^ids and s.enabled)
      |> join(:inner, [s], d in assoc(s, :document))
      |> then(fn query ->
        # Tag filter: only segments from documents carrying any of the
        # requested tags.
        if tags == [] do
          query
        else
          where(query, [s, d], fragment("? && ?", d.tags, ^tags))
        end
      end)
      |> then(fn query ->
        # Metadata filter: JSONB containment — the document must carry
        # every requested key/value pair.
        if metadata_filter == %{} do
          query
        else
          where(query, [s, d], fragment("? @> ?", d.metadata, ^metadata_filter))
        end
      end)
      |> preload([s, d], document: d)
      |> Repo.all()
      |> Enum.sort_by(&Map.fetch!(scores, &1.id), :desc)
      |> Enum.map(&Map.put(&1, :score, Map.fetch!(scores, &1.id)))

    hits =
      dataset
      |> maybe_rerank(query, segments, top_k, rerank?)
      |> apply_threshold(dataset.score_threshold)
      |> promote_parents()

    {:ok, hits}
  end

  # Parent-child hits surface the parent section instead of the matched
  # child, deduplicated (best score wins the slot, order preserved).
  defp promote_parents(hits) do
    {promoted, _seen} =
      Enum.reduce(hits, {[], MapSet.new()}, fn segment, {acc, seen} ->
        case segment.parent_content do
          nil ->
            {[segment | acc], seen}

          parent ->
            key = {segment.document_id, :erlang.phash2(parent)}

            if MapSet.member?(seen, key) do
              {acc, seen}
            else
              {[%{segment | content: parent} | acc], MapSet.put(seen, key)}
            end
        end
      end)

    Enum.reverse(promoted)
  end

  # Up to two alternate phrasings from the workspace default model —
  # best-effort (a failed or absent model expands to nothing), and tests
  # inject `config :flux, :query_expander`.
  defp expand_query(scope, %Dataset{query_expansion: true}, query) do
    case Application.get_env(:flux, :query_expander) do
      expander when is_function(expander, 1) ->
        expander.(query)

      nil ->
        prompt = """
        Rephrase this search query two different ways — different words,
        same meaning. One rephrasing per line, nothing else.

        Query: #{query}
        """

        case Flux.Workflows.invoke_default_llm(scope, [%{role: :user, content: prompt}]) do
          {:ok, content} when is_binary(content) ->
            content
            |> String.split(~r/\r?\n/, trim: true)
            |> Enum.map(&String.trim(&1, "- "))
            |> Enum.reject(&(&1 == "" or String.length(&1) > 300))
            |> Enum.take(2)

          _error_or_no_model ->
            []
        end
    end
  end

  defp expand_query(_scope, _dataset, _query), do: []

  defp apply_threshold(hits, nil), do: hits

  defp apply_threshold(hits, threshold),
    do: Enum.filter(hits, &(&1.score >= threshold))

  # A configured rerank model reorders the RRF candidates and replaces
  # the scores; failures fall back to the fused ranking untouched.
  defp maybe_rerank(_dataset, _query, segments, top_k, false), do: Enum.take(segments, top_k)

  defp maybe_rerank(dataset, query, segments, top_k, true) do
    case Flux.Providers.rerank_texts(
           dataset.workspace_id,
           dataset.rerank_plugin_id,
           dataset.rerank_model,
           query,
           Enum.map(segments, & &1.content)
         ) do
      {:ok, ranking} ->
        ranking
        |> Enum.take(top_k)
        |> Enum.map(fn %{index: index, score: score} ->
          segments |> Enum.at(index) |> Map.put(:score, score)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        Enum.take(segments, top_k)
    end
  end

  @doc """
  Retrieves across several datasets and merges by score (best first).
  Unknown dataset ids are skipped.
  """
  def retrieve_many(%Scope{} = scope, dataset_ids, query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k) || 4

    hits =
      dataset_ids
      |> Enum.flat_map(fn dataset_id ->
        case retrieve(scope, dataset_id, query, opts) do
          {:ok, hits} -> hits
          _missing -> []
        end
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(top_k)

    {:ok, hits}
  end

  defp semantic_hits(dataset, query, limit) do
    case embed(dataset, [query]) do
      {:ok, [vector]} ->
        dataset.id
        |> VectorStore.backend().search(vector, limit)
        |> Enum.map(& &1.segment_id)

      _no_embeddings ->
        []
    end
  end

  # Third RRF source: segments mentioning the entities named in the query,
  # ranked by how many distinct query entities they share. Queries with no
  # recognizable entities contribute nothing (empty ranking is a no-op).
  defp entity_hits(scope, dataset_id, query, limit) do
    case Entities.extract(query) do
      [] ->
        []

      names ->
        EntityMention
        |> Repo.scoped(scope)
        |> join(:inner, [m], e in Entity, on: m.entity_id == e.id)
        |> join(:inner, [m], s in Segment, on: m.segment_id == s.id)
        |> where([m, e, s], m.dataset_id == ^dataset_id and e.name in ^names and s.enabled)
        |> group_by([m], m.segment_id)
        |> order_by([m, e], desc: count(e.id, :distinct))
        |> limit(^limit)
        |> select([m], m.segment_id)
        |> Repo.all()
    end
  end

  defp keyword_hits(scope, dataset_id, query, limit) do
    Segment
    |> Repo.scoped(scope)
    |> where([s], s.dataset_id == ^dataset_id and s.enabled)
    |> where(
      [s],
      fragment("to_tsvector('english', ?) @@ plainto_tsquery('english', ?)", s.content, ^query)
    )
    |> order_by([s],
      desc:
        fragment(
          "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
          s.content,
          ^query
        )
    )
    |> limit(^limit)
    |> select([s], s.id)
    |> Repo.all()
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end

defmodule Flux.RAG.SyncSweepWorker do
  @moduledoc """
  Oban cron (every 5 minutes): enqueues a datasource sync for every
  dataset whose auto-sync interval has elapsed. `last_synced_at` marks
  the enqueue (not completion) so a slow source can't pile up jobs.
  """
  use Oban.Worker, queue: :ingest, max_attempts: 1

  import Ecto.Query

  alias Flux.RAG.Dataset
  alias Flux.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now(:second)

    due =
      from(d in Dataset,
        where: not is_nil(d.sync_plugin_id) and not is_nil(d.sync_interval_minutes),
        where:
          is_nil(d.last_synced_at) or
            d.last_synced_at <=
              datetime_add(^now, fragment("-?", d.sync_interval_minutes), "minute")
      )
      |> Repo.all(skip_workspace_guard: true)

    for dataset <- due do
      dataset |> Ecto.Changeset.change(last_synced_at: now) |> Repo.update()

      # An uninstalled plugin pauses the schedule instead of erroring.
      if Flux.Tools.plugin_installed?(dataset.workspace_id, dataset.sync_plugin_id) do
        {:ok, _job} =
          %{dataset_id: dataset.id, plugin_id: dataset.sync_plugin_id}
          |> Flux.RAG.DatasourceSyncWorker.new()
          |> Oban.insert()
      end
    end

    :ok
  end
end

defmodule Flux.RAG.DatasourceSyncWorker do
  @moduledoc "Oban worker: syncs one datasource plugin into one dataset."
  use Oban.Worker, queue: :ingest, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dataset_id" => dataset_id, "plugin_id" => plugin_id}}) do
    case Flux.RAG.sync_dataset_from_datasource(dataset_id, plugin_id) do
      {:ok, _added} -> :ok
      # Feed/API errors are often transient — let Oban retry.
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Flux.RAG.IndexWorker do
  @moduledoc "Oban worker: splits, embeds, and indexes one document."
  use Oban.Worker, queue: :ingest, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id}}) do
    case Flux.RAG.index_document(document_id) do
      :ok -> :ok
      # Embedding errors are often transient (rate limits) — let Oban retry.
      {:error, reason} -> {:error, reason}
    end
  end
end
