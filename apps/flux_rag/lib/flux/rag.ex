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
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      # `replace: true` swaps out same-named documents instead of
      # duplicating — re-uploading a file updates the dataset in place.
      if Keyword.get(opts, :replace, false) do
        Document
        |> Repo.scoped(scope)
        |> where([d], d.dataset_id == ^dataset.id and d.name == ^name)
        |> Repo.all()
        |> Enum.each(&Repo.delete/1)
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

          {:ok, Enum.sum(added)}
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

  def delete_document(%Scope{} = scope, document_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Document{} = document <-
           Repo.one(Repo.scoped(where(Document, id: ^document_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(document)
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

        document
        |> Ecto.Changeset.change(status: :ready, segment_count: length(segments), error: nil)
        |> Repo.update!()

        :ok

      {:error, reason} ->
        document
        |> Ecto.Changeset.change(status: :error, error: format_error(reason))
        |> Repo.update!()

        {:error, reason}
    end
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
      top_k = Keyword.get(opts, :top_k) || dataset.retrieval_top_k || 4
      rerank? = dataset.rerank_plugin_id not in [nil, ""]
      candidates = if rerank?, do: top_k * 3, else: top_k

      # Query expansion (per-dataset opt-in): alternate phrasings each
      # contribute their own rankings to the RRF fusion.
      queries = [query | expand_query(scope, dataset, query)]

      rankings =
        Enum.flat_map(queries, fn variant ->
          [
            semantic_hits(dataset, variant, top_k * 3),
            keyword_hits(scope, dataset_id, variant, top_k * 3),
            entity_hits(scope, dataset_id, variant, top_k * 3)
          ]
        end)

      ranked =
        rankings
        |> Enum.reduce(%{}, fn hits, acc ->
          hits
          |> Enum.with_index(1)
          |> Enum.reduce(acc, fn {segment_id, rank}, acc ->
            Map.update(acc, segment_id, 1 / (@rrf_k + rank), &(&1 + 1 / (@rrf_k + rank)))
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
