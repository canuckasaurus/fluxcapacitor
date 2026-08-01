defmodule FluxWeb.RAGIntegrationTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.RAG

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "RAG WS"})
    scope = Accounts.scope_for(account)

    {:ok, dataset} =
      RAG.create_dataset(scope, %{
        "name" => "Handbook",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    %{scope: scope, dataset: dataset, workspace: workspace}
  end

  defp ingest!(scope, dataset, name, content) do
    {:ok, document} = RAG.add_document(scope, dataset, %{name: name, content: content})
    Oban.drain_queue(queue: :ingest)
    Flux.Repo.get!(Flux.RAG.Document, document.id, skip_workspace_guard: true)
  end

  test "chunker splits long text with overlap" do
    paragraphs = Enum.map_join(1..12, "\n\n", fn n -> String.duplicate("word#{n} ", 40) end)
    chunks = Flux.RAG.Chunker.split(paragraphs)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= 1_200))
    # Overlap: later chunks carry a tail of the previous one.
    assert Enum.at(chunks, 1) =~ "…"
  end

  test "documents ingest through Oban into ready segments", %{scope: scope, dataset: dataset} do
    document =
      ingest!(scope, dataset, "vacation.md", """
      Vacation policy: employees receive 25 paid days per year.

      Unused days roll over for one quarter, then expire.
      """)

    assert document.status == :ready
    assert document.segment_count >= 1

    segments = RAG.list_segments(scope, document.id)
    assert Enum.any?(segments, &(&1.content =~ "25 paid days"))
    assert Enum.all?(segments, &is_list(&1.embedding))
  end

  test "hybrid retrieval finds the relevant segment first", %{scope: scope, dataset: dataset} do
    ingest!(scope, dataset, "vacation.md", """
    Vacation policy: employees receive 25 paid days of vacation per year.
    """)

    ingest!(scope, dataset, "security.md", """
    Security policy: rotate credentials quarterly and enable two-factor auth.
    """)

    ingest!(scope, dataset, "kitchen.md", """
    Kitchen rules: label your food and empty the dishwasher when full.
    """)

    {:ok, results} = RAG.retrieve(scope, dataset.id, "how many vacation days do I get?")

    assert [top | _rest] = results
    assert top.content =~ "25 paid days"
    assert top.document.name == "vacation.md"
    assert top.score > 0
  end

  test "embedding failures mark the document error and Oban retries", %{scope: scope} do
    {:ok, broken} =
      RAG.create_dataset(scope, %{
        "name" => "Broken",
        "embedding_plugin_id" => "anthropic",
        "embedding_model" => "nope"
      })

    {:ok, document} = RAG.add_document(scope, broken, %{name: "x.txt", content: "hello"})
    Oban.drain_queue(queue: :ingest)

    updated = Flux.Repo.get!(Flux.RAG.Document, document.id, skip_workspace_guard: true)
    assert updated.status == :error
    assert updated.error =~ "not_supported"
  end

  test "a flux run retrieves through the knowledge node end-to-end", %{
    scope: scope,
    dataset: dataset
  } do
    ingest!(scope, dataset, "vacation.md", """
    Vacation policy: employees receive 25 paid days of vacation per year.
    """)

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "KB Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [
              %{"name" => "query", "label" => "Query", "type" => "text", "required" => true}
            ]
          }
        },
        %{
          "id" => "kb",
          "type" => "knowledge_retrieval",
          "title" => "Knowledge",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{"dataset_id" => dataset.id, "query" => "{{start.query}}", "top_k" => 2}
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "position" => %{"x" => 600, "y" => 0},
          "config" => %{"answer" => "From the handbook: {{kb.result}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "kb"},
        %{"id" => "e2", "source" => "kb", "source_handle" => "default", "target" => "answer_1"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "vacation days"})

    finished =
      receive do
        {:run_finished, finished} -> finished
      after
        5_000 -> flunk("run did not finish")
      end

    assert finished.status == :succeeded
    assert finished.outputs["answer"] =~ "25 paid days"
  end

  test "add_document_from_url fetches, strips, and indexes", %{scope: scope, dataset: dataset} do
    Application.put_env(:flux_rag, :req_options, plug: {Req.Test, Flux.RAGUrlStub})
    on_exit(fn -> Application.delete_env(:flux_rag, :req_options) end)

    Req.Test.stub(Flux.RAGUrlStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(
        200,
        "<html><body><h1>Docs</h1><p>Deploys happen every Tuesday.</p></body></html>"
      )
    end)

    {:ok, document} =
      RAG.add_document_from_url(scope, dataset, "https://example.com/docs/deploys")

    assert document.name == "example.com/docs/deploys"
    Oban.drain_queue(queue: :ingest)

    ready = Flux.Repo.get!(Flux.RAG.Document, document.id, skip_workspace_guard: true)
    assert ready.status == :ready
    assert ready.content =~ "Deploys happen every Tuesday."
    refute ready.content =~ "<p>"
  end

  test "a configured rerank model reorders retrieval results", %{scope: scope, dataset: dataset} do
    ingest!(scope, dataset, "a.md", "Bananas are yellow fruit.")
    ingest!(scope, dataset, "b.md", "Vacation days: employees receive 25 vacation days.")
    ingest!(scope, dataset, "c.md", "The dishwasher schedule is on the fridge.")

    {:ok, dataset} =
      RAG.update_dataset(scope, dataset, %{
        "rerank_plugin_id" => "echo",
        "rerank_model" => "echo-rerank"
      })

    {:ok, [top | _]} = RAG.retrieve(scope, dataset.id, "how many vacation days", top_k: 2)
    assert top.document.name == "b.md"
    assert top.score > 0
  end

  test "re-index re-chunks with updated dataset settings", %{scope: scope, dataset: dataset} do
    long_text = Enum.map_join(1..8, "\n\n", fn n -> String.duplicate("chunkword#{n} ", 30) end)
    document = ingest!(scope, dataset, "big.md", long_text)
    original_count = document.segment_count

    # Smaller chunks → more segments after re-index.
    {:ok, dataset} =
      RAG.update_dataset(scope, dataset, %{"chunk_size" => 200, "chunk_overlap" => 0})

    {:ok, 1} = RAG.reindex_dataset(scope, dataset)
    Oban.drain_queue(queue: :ingest)

    reindexed = Flux.Repo.get!(Flux.RAG.Document, document.id, skip_workspace_guard: true)
    assert reindexed.status == :ready
    assert reindexed.segment_count > original_count

    # No stale segments left behind.
    segments = RAG.list_segments(scope, document.id, 500)
    assert length(segments) == reindexed.segment_count
  end

  test "chatflow answers carry knowledge citations", %{scope: scope, dataset: dataset} do
    ingest!(scope, dataset, "vacation.md", "Vacation policy: 25 paid days per year.")

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Cited Chatflow"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{"variables" => []}
        },
        %{
          "id" => "kb",
          "type" => "knowledge_retrieval",
          "title" => "Knowledge",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{"dataset_id" => dataset.id, "query" => "{{sys.query}}", "top_k" => 2}
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "position" => %{"x" => 600, "y" => 0},
          "config" => %{"answer" => "According to the handbook: {{kb.result}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "kb"},
        %{"id" => "e2", "source" => "kb", "source_handle" => "default", "target" => "answer_1"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _version} = Flux.Workflows.publish(scope, workflow)

    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Cited App",
        "mode" => "advanced_chat",
        "workflow_id" => workflow.id
      })

    conversation = Flux.Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Flux.Chat.send_message(scope, app, conversation, "vacation days?")

    assert_receive {:done, final}, 5_000
    assert final.content =~ "25 paid days"
    assert [citation | _] = final.citations
    assert citation["document"] == "vacation.md"
  end

  test "retrieve_many merges hits across datasets", %{scope: scope, dataset: dataset} do
    ingest!(scope, dataset, "vacation.md", "Vacation policy: 25 paid vacation days per year.")

    {:ok, second} =
      RAG.create_dataset(scope, %{
        "name" => "IT KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    ingest!(
      scope,
      second,
      "vpn.md",
      "VPN setup: install the client and use your vacation... no, your SSO login."
    )

    {:ok, hits} =
      RAG.retrieve_many(scope, [dataset.id, second.id], "how many vacation days?", top_k: 3)

    names = hits |> Enum.map(& &1.document.name) |> Enum.uniq()
    assert "vacation.md" in names
    assert hd(hits).document.name == "vacation.md"
  end

  test "datasource sync pulls feed items into the dataset once", %{
    scope: scope,
    dataset: dataset
  } do
    feed = """
    <rss version="2.0"><channel>
      <item>
        <title>Release notes</title>
        <link>https://blog.example.com/release</link>
        <guid>rel-1</guid>
        <description>Version 2 ships multi-dataset retrieval.</description>
      </item>
      <item>
        <title>Hiring update</title>
        <link>https://blog.example.com/hiring</link>
        <guid>hire-1</guid>
        <description>We are hiring two Elixir engineers.</description>
      </item>
    </channel></rss>
    """

    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.RSSSyncStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    Req.Test.stub(Flux.RSSSyncStub, fn conn -> Plug.Conn.send_resp(conn, 200, feed) end)

    # Not installed yet → refused.
    assert {:error, :plugin_not_installed} = RAG.sync_datasource(scope, dataset, "rss")

    :ok = Flux.Tools.install_plugin(scope, "rss")

    {:ok, _credential} =
      Flux.Providers.upsert_credential(scope, "rss", %{
        "feed_url" => "https://feeds.example.com/blog.xml"
      })

    {:ok, _job} = RAG.sync_datasource(scope, dataset, "rss")
    Oban.drain_queue(queue: :ingest, with_recursion: true)

    documents = RAG.list_documents(scope, dataset.id)
    assert documents |> Enum.map(& &1.name) |> Enum.sort() == ["Hiring update", "Release notes"]
    assert Enum.all?(documents, &(&1.status == :ready))

    {:ok, hits} = RAG.retrieve(scope, dataset.id, "are we hiring engineers?")
    assert hd(hits).document.name == "Hiring update"

    # Re-sync is idempotent: already-synced names are skipped.
    {:ok, _job} = RAG.sync_datasource(scope, dataset, "rss")
    Oban.drain_queue(queue: :ingest, with_recursion: true)
    assert length(RAG.list_documents(scope, dataset.id)) == 2
  end

  test "dataset mutations enforce RBAC", %{workspace: workspace, dataset: dataset} do
    viewer = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: viewer.id,
        role: :normal
      })
      |> Flux.Repo.insert()

    {:ok, _} = Accounts.switch_workspace(viewer, workspace.id)
    viewer_scope = Accounts.scope_for(viewer)

    assert {:error, :unauthorized} =
             RAG.create_dataset(viewer_scope, %{
               "name" => "No",
               "embedding_plugin_id" => "echo",
               "embedding_model" => "echo-embed"
             })

    assert {:error, :unauthorized} =
             RAG.add_document(viewer_scope, dataset, %{name: "n", content: "c"})
  end
end
