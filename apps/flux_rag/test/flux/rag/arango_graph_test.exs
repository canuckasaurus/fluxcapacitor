defmodule Flux.RAG.ArangoGraphTest do
  use ExUnit.Case, async: false

  alias Flux.RAG.ArangoGraph

  setup do
    Application.put_env(:flux, ArangoGraph,
      url: "http://arango.test:8529",
      password: "secret",
      database: "flux_test"
    )

    Application.put_env(:flux, :arango_req_options, plug: {Req.Test, ArangoGraph})
    :persistent_term.erase({ArangoGraph, :setup})

    on_exit(fn ->
      Application.delete_env(:flux, ArangoGraph)
      Application.delete_env(:flux, :arango_req_options)
      :persistent_term.erase({ArangoGraph, :setup})
    end)

    :ok
  end

  test "unconfigured is a clean no" do
    Application.delete_env(:flux, ArangoGraph)
    refute ArangoGraph.configured?()
  end

  test "sync creates the database/collections and imports vertices and edges" do
    test_pid = self()

    Req.Test.stub(ArangoGraph, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:arango, conn.method, conn.request_path, body})

      case conn.request_path do
        "/_api/database" -> Req.Test.json(conn, %{"result" => true})
        "/_db/flux_test/_api/collection" -> Req.Test.json(conn, %{"name" => "ok"})
        "/_db/flux_test/_api/import" -> Req.Test.json(conn, %{"created" => 2})
      end
    end)

    entities = [%{name: "flux capacitor"}, %{name: "delorean"}]
    pairs = %{{"delorean", "flux capacitor"} => 3}

    assert :ok = ArangoGraph.sync_dataset("ds-1", entities, pairs)

    assert_received {:arango, "POST", "/_api/database", _body}
    assert_received {:arango, "POST", "/_db/flux_test/_api/collection", _body}
    assert_received {:arango, "POST", "/_db/flux_test/_api/collection", _body}
    assert_received {:arango, "POST", "/_db/flux_test/_api/import", vertices_body}
    assert vertices_body =~ "flux capacitor"
    assert_received {:arango, "POST", "/_db/flux_test/_api/import", edges_body}
    assert edges_body =~ ~s("weight":3)
    assert edges_body =~ "entities/"
  end

  test "the Arango vector backend indexes embeddings and ranks by cosine" do
    alias Flux.RAG.VectorStore.Arango

    Req.Test.stub(ArangoGraph, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/_api/database" ->
          Req.Test.json(conn, %{"result" => true})

        "/_db/flux_test/_api/collection" ->
          Req.Test.json(conn, %{"name" => "segments"})

        "/_db/flux_test/_api/import" ->
          assert body =~ ~s("embedding":[1.0,0.0])
          Req.Test.json(conn, %{"created" => 1})

        "/_db/flux_test/_api/cursor" ->
          decoded = Jason.decode!(body)
          assert decoded["query"] =~ "COSINE_SIMILARITY"
          assert decoded["bindVars"]["dataset_id"] == "ds-1"

          Req.Test.json(conn, %{"result" => [%{"id" => "seg-1", "score" => 0.97}]})
      end
    end)

    assert :ok = Arango.index("ds-1", [%{id: "seg-1", embedding: [1.0, 0.0]}])

    assert [%{segment_id: "seg-1", score: 0.97}] = Arango.search("ds-1", [1.0, 0.1], 4)

    # Unconfigured: empty ranking, hybrid retrieval degrades gracefully.
    Application.delete_env(:flux, ArangoGraph)
    assert Arango.search("ds-1", [1.0], 4) == []
  end

  test "related runs the traversal and maps results (errors surface for fallback)" do
    Req.Test.stub(ArangoGraph, fn conn ->
      case conn.request_path do
        "/_db/flux_test/_api/cursor" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["query"] =~ "1..2 ANY @start cooccurs"
          assert decoded["bindVars"]["dataset_id"] == "ds-1"

          Req.Test.json(conn, %{
            "result" => [%{"name" => "delorean", "weight" => 3, "depth" => 1}]
          })
      end
    end)

    assert {:ok, [%{name: "delorean", weight: 3, depth: 1}]} =
             ArangoGraph.related("ds-1", "flux capacitor", 5)

    Req.Test.stub(ArangoGraph, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => true})
    end)

    assert {:error, _reason} = ArangoGraph.related("ds-1", "flux capacitor", 5)
  end
end
