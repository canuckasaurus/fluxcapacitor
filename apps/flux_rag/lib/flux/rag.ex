defmodule Flux.RAG do
  @moduledoc """
  Knowledge pillar: datasets → documents → embedded segments, with hybrid
  retrieval (semantic cosine + Postgres full-text, merged by reciprocal
  rank fusion). Ingestion runs on Oban (`:ingest` queue); embeddings go
  through the workspace's configured provider.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.RAG.{Chunker, Dataset, Document, Segment, VectorStore}
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
  """
  def retrieve(%Scope{} = scope, dataset_id, query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 4)

    with %Dataset{} = dataset <- get_dataset(scope, dataset_id) do
      rerank? = dataset.rerank_plugin_id not in [nil, ""]
      candidates = if rerank?, do: top_k * 3, else: top_k

      semantic_hits = semantic_hits(dataset, query, top_k * 3)
      keyword_hits = keyword_hits(scope, dataset_id, query, top_k * 3)

      ranked =
        [semantic_hits, keyword_hits]
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
        |> where([s], s.id in ^ids)
        |> join(:inner, [s], d in assoc(s, :document))
        |> preload([s, d], document: d)
        |> Repo.all()
        |> Enum.sort_by(&Map.fetch!(scores, &1.id), :desc)
        |> Enum.map(&Map.put(&1, :score, Map.fetch!(scores, &1.id)))

      {:ok, maybe_rerank(dataset, query, segments, top_k, rerank?)}
    end
  end

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

  defp keyword_hits(scope, dataset_id, query, limit) do
    Segment
    |> Repo.scoped(scope)
    |> where([s], s.dataset_id == ^dataset_id)
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
