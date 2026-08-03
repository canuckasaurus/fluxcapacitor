defmodule FluxWeb.Perf.RetrievalBenchTest do
  @moduledoc """
  Vector-backend benchmark at corpus scale: 10k embedded segments, the
  same query against every available backend. Naive always runs;
  PgVector runs when the database has the extension; Arango runs when
  FLUX_ARANGO_URL points at a live server. Excluded by default:

      mix test --include perf apps/flux_web/test/perf
  """
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.RAG.VectorStore

  @moduletag :perf
  @moduletag timeout: 300_000

  @segments 10_000
  @dims 16

  test "backends rank 10k segments within bounds" do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Bench WS"})
    scope = Accounts.scope_for(account)

    {:ok, dataset} =
      Flux.RAG.create_dataset(scope, %{
        "name" => "Bench KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    seed(workspace.id, dataset.id)
    query_vector = vector(4_242)

    {naive_us, naive_hits} =
      :timer.tc(fn -> VectorStore.Naive.search(dataset.id, query_vector, 5) end)

    IO.puts("\nretrieval bench @ #{@segments} segments:")
    IO.puts("  naive:    #{div(naive_us, 1000)} ms")

    assert length(naive_hits) == 5
    assert hd(naive_hits).score > 0.99
    assert naive_us < 30_000_000

    if VectorStore.PgVector.available?() do
      :ok = VectorStore.PgVector.index(dataset.id, [])

      {pg_us, pg_hits} =
        :timer.tc(fn -> VectorStore.PgVector.search(dataset.id, query_vector, 5) end)

      IO.puts("  pgvector: #{div(pg_us, 1000)} ms")
      assert length(pg_hits) == 5
      assert hd(pg_hits).segment_id == hd(naive_hits).segment_id
      assert pg_us < 10_000_000
    else
      IO.puts("  pgvector: unavailable on this database (skipped)")
    end

    if Flux.RAG.ArangoGraph.configured?() do
      segments =
        Flux.RAG.Segment
        |> Flux.Repo.scoped(scope)
        |> Flux.Repo.all()

      {index_us, :ok} = :timer.tc(fn -> VectorStore.Arango.index(dataset.id, segments) end)

      {arango_us, arango_hits} =
        :timer.tc(fn -> VectorStore.Arango.search(dataset.id, query_vector, 5) end)

      IO.puts("  arango:   #{div(arango_us, 1000)} ms (index #{div(index_us, 1000)} ms)")
      assert length(arango_hits) == 5
      assert hd(arango_hits).segment_id == hd(naive_hits).segment_id
    else
      IO.puts("  arango:   not configured (skipped)")
    end
  end

  defp seed(workspace_id, dataset_id) do
    now = DateTime.utc_now(:second)
    document_id = UUIDv7.generate()

    Flux.Repo.insert_all(
      Flux.RAG.Document,
      [
        %{
          id: document_id,
          workspace_id: workspace_id,
          dataset_id: dataset_id,
          name: "bench.md",
          status: :ready,
          segment_count: @segments,
          inserted_at: now,
          updated_at: now
        }
      ],
      skip_workspace_guard: true
    )

    0..(@segments - 1)
    |> Enum.map(fn index ->
      %{
        id: UUIDv7.generate(),
        workspace_id: workspace_id,
        dataset_id: dataset_id,
        document_id: document_id,
        position: index,
        content: "Bench segment #{index}",
        embedding: vector(index),
        enabled: true,
        inserted_at: now
      }
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      Flux.Repo.insert_all(Flux.RAG.Segment, chunk, skip_workspace_guard: true)
    end)
  end

  defp vector(index) do
    for dim <- 1..@dims, do: :math.sin(index * dim * 0.1)
  end
end
