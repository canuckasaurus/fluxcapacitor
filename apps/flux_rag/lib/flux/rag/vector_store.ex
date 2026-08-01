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
      where: s.dataset_id == ^dataset_id and not is_nil(s.embedding),
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
