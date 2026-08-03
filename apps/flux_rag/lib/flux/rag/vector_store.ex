defmodule Flux.RAG.VectorStore do
  @moduledoc """
  Replaceable vector index behind the RAG pipeline. Postgres stays the
  system of record (segments); a backend only answers similarity queries.
  The `Naive` backend keeps CI hermetic; ArangoDB slots in behind the
  same behaviour when the Docker stack lands (see PARITY-PLAN WS3).
  """

  @type hit :: %{segment_id: String.t(), score: float()}

  @callback index(dataset_id :: String.t(), segments :: [map()]) :: :ok | {:error, term()}
  @callback search(dataset_id :: String.t(), vector :: [float()], top_k :: pos_integer()) ::
              [hit()]
  @callback drop(dataset_id :: String.t()) :: :ok

  def backend do
    Application.get_env(:flux, :vector_store, Flux.RAG.VectorStore.Naive)
  end
end

defmodule Flux.RAG.VectorStore.PgVector do
  @moduledoc """
  pgvector-backed similarity: the guarded migration adds an
  `embedding_vec vector` column when the extension is available, `index`
  mirrors the float-array embeddings into it, and `search` ranks by
  cosine distance in SQL — exact but database-side, orders of magnitude
  faster than the Naive backend at corpus scale.

  Select it with `FLUX_VECTOR_BACKEND=pgvector` (the compose Postgres
  image ships the extension). `available?/0` reports whether the current
  database can serve it.
  """
  @behaviour Flux.RAG.VectorStore

  alias Flux.Repo

  @doc "Whether the connected database has the vector extension installed."
  def available? do
    case Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'vector'") do
      {:ok, %{num_rows: num_rows}} -> num_rows > 0
      _error -> false
    end
  end

  @impl true
  def index(dataset_id, _segments) do
    {:ok, dataset_uuid} = Ecto.UUID.dump(dataset_id)

    Repo.query!(
      """
      UPDATE rag_segments
      SET embedding_vec = embedding::vector
      WHERE dataset_id = $1 AND embedding IS NOT NULL
        AND (embedding_vec IS NULL OR embedding_vec::text != embedding::vector::text)
      """,
      [dataset_uuid]
    )

    :ok
  end

  @impl true
  def search(dataset_id, vector, top_k) do
    {:ok, dataset_uuid} = Ecto.UUID.dump(dataset_id)
    literal = "[" <> Enum.map_join(vector, ",", &to_string/1) <> "]"

    %{rows: rows} =
      Repo.query!(
        """
        SELECT id, 1 - (embedding_vec <=> $1::vector) AS score
        FROM rag_segments
        WHERE dataset_id = $2 AND enabled AND embedding_vec IS NOT NULL
        ORDER BY embedding_vec <=> $1::vector
        LIMIT $3
        """,
        [literal, dataset_uuid, top_k]
      )

    for [id, score] <- rows do
      {:ok, segment_id} = Ecto.UUID.load(id)
      %{segment_id: segment_id, score: score * 1.0}
    end
  end

  @impl true
  def drop(_dataset_id), do: :ok
end

defmodule Flux.RAG.VectorStore.Naive do
  @moduledoc """
  Exact cosine similarity over the segments already stored in Postgres —
  no extra infrastructure, correct at small/medium corpus sizes. Indexing
  is a no-op (the segment insert IS the index).
  """
  @behaviour Flux.RAG.VectorStore

  import Ecto.Query

  alias Flux.RAG.Segment
  alias Flux.Repo

  @impl true
  def index(_dataset_id, _segments), do: :ok

  @impl true
  def search(dataset_id, vector, top_k) do
    from(s in Segment,
      where: s.dataset_id == ^dataset_id and not is_nil(s.embedding) and s.enabled,
      select: %{id: s.id, embedding: s.embedding}
    )
    |> Repo.all(skip_workspace_guard: true)
    |> Enum.map(fn segment ->
      %{segment_id: segment.id, score: cosine(vector, segment.embedding)}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  @impl true
  def drop(_dataset_id), do: :ok

  defp cosine(a, b) when length(a) == length(b) do
    {dot, mag_a, mag_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, ma, mb} ->
        {dot + x * y, ma + x * x, mb + y * y}
      end)

    denominator = :math.sqrt(mag_a) * :math.sqrt(mag_b)
    if denominator == 0.0, do: 0.0, else: dot / denominator
  end

  defp cosine(_a, _b), do: 0.0
end
