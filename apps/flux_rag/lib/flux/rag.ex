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
    Dataset |> Repo.scoped(scope) |> order_by([d], desc: d.inserted_at) |> Repo.all()
  end

  def get_dataset(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Dataset, id: ^id), scope)) || {:error, :not_found}
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
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      dataset |> Dataset.changeset(attrs) |> Repo.update()
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

  def delete_dataset(%Scope{} = scope, %Dataset{} = dataset) do
    with :ok <- RBAC.authorize(scope, :dataset_delete),
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, deleted} <- Repo.delete(dataset) do
      VectorStore.backend().drop(dataset.id)
      Flux.Audit.record(scope, "dataset.delete", resource: dataset)
      {:ok, deleted}
    end
  end

  ## Documents & ingestion

  @doc """
  Adds a text document and enqueues indexing (extract for files happens
  before this via `Flux.Documents`). Returns the pending document.
  """
  def add_document(%Scope{} = scope, %Dataset{} = dataset, %{name: name, content: content})
      when is_binary(content) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         true <- dataset.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
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
        add_document(scope, dataset, %{name: name, content: content})
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
  Starts a background sync of an installed datasource plugin into the
  dataset: every document the source offers that the dataset doesn't
  already hold (by name) is fetched and indexed.
  """
  def sync_datasource(%Scope{} = scope, %Dataset{} = dataset, plugin_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
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
      {:ok, updated}
    end
  end

  @doc "Disabled segments stay stored but are excluded from retrieval."
  def set_segment_enabled(%Scope{} = scope, segment_id, enabled) when is_boolean(enabled) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Segment{} = segment <- fetch_segment(scope, segment_id) do
      segment |> Ecto.Changeset.change(enabled: enabled) |> Repo.update()
    end
  end

  def delete_segment(%Scope{} = scope, segment_id) do
    with :ok <- RBAC.authorize(scope, :dataset_edit),
         %Segment{} = segment <- fetch_segment(scope, segment_id),
         {:ok, deleted} <- Repo.delete(segment) do
      from(d in Document, where: d.id == ^segment.document_id)
      |> Repo.update_all([inc: [segment_count: -1]], skip_workspace_guard: true)

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

    chunks =
      Chunker.split(document.content || "",
        max_chars: dataset.chunk_size || 1000,
        overlap: dataset.chunk_overlap || 120
      )

    case embed(dataset, chunks) do
      {:ok, vectors} ->
        segments =
          for {{chunk, vector}, position} <- Enum.with_index(Enum.zip(chunks, vectors)) do
            Repo.insert!(%Segment{
              workspace_id: document.workspace_id,
              dataset_id: dataset.id,
              document_id: document.id,
              position: position,
              content: chunk,
              embedding: vector
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
          names = Entities.extract(segment.content),
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

    :ok
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

      semantic_hits = semantic_hits(dataset, query, top_k * 3)
      keyword_hits = keyword_hits(scope, dataset_id, query, top_k * 3)
      entity_hits = entity_hits(scope, dataset_id, query, top_k * 3)

      ranked =
        [semantic_hits, keyword_hits, entity_hits]
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

      segments =
        Segment
        |> Repo.scoped(scope)
        |> where([s], s.id in ^ids and s.enabled)
        |> join(:inner, [s], d in assoc(s, :document))
        |> preload([s, d], document: d)
        |> Repo.all()
        |> Enum.sort_by(&Map.fetch!(scores, &1.id), :desc)
        |> Enum.map(&Map.put(&1, :score, Map.fetch!(scores, &1.id)))

      hits =
        dataset
        |> maybe_rerank(query, segments, top_k, rerank?)
        |> apply_threshold(dataset.score_threshold)

      {:ok, hits}
    end
  end

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
