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

  test "deleted datasets land in the trash and restore", %{scope: scope, dataset: dataset} do
    {:ok, trashed} = RAG.delete_dataset(scope, dataset)
    assert trashed.deleted_at != nil

    # Gone from listings, retrieval, and lookups — but restorable.
    assert RAG.list_datasets(scope) == []
    assert {:error, :not_found} = RAG.get_dataset(scope, dataset.id)
    assert [%{name: "Handbook"}] = RAG.list_trashed_datasets(scope)

    {:ok, restored} = RAG.restore_dataset(scope, dataset.id)
    assert restored.deleted_at == nil
    assert [_dataset] = RAG.list_datasets(scope)
  end

  test "document tags filter retrieval", %{scope: scope, dataset: dataset} do
    policy = ingest!(scope, dataset, "policy.md", "Refunds follow the thirty day policy window.")
    _blog = ingest!(scope, dataset, "blog.md", "Our blog post also mentions the policy loosely.")

    {:ok, _document} = RAG.set_document_tags(scope, policy.id, ["Policy", " official ", ""])

    tagged = Flux.Repo.get!(Flux.RAG.Document, policy.id, skip_workspace_guard: true)
    assert tagged.tags == ["policy", "official"]

    {:ok, all_hits} = RAG.retrieve(scope, dataset.id, "policy window")
    assert length(Enum.uniq_by(all_hits, & &1.document_id)) == 2

    {:ok, filtered} = RAG.retrieve(scope, dataset.id, "policy window", tags: ["policy"])
    assert filtered != []
    assert Enum.all?(filtered, &(&1.document_id == policy.id))

    {:ok, none} = RAG.retrieve(scope, dataset.id, "policy window", tags: ["nonexistent"])
    assert none == []
  end

  test "query expansion fuses rankings from rephrased queries", %{
    scope: scope,
    dataset: dataset
  } do
    ingest!(scope, dataset, "spice.md", "The secret ingredient is paprika, nothing else.")

    # The injected expander stands in for the workspace model.
    Application.put_env(:flux, :query_expander, fn query ->
      send(self(), {:expanded, query})
      ["secret ingredient paprika"]
    end)

    on_exit(fn -> Application.delete_env(:flux, :query_expander) end)

    # Off (default): the expander never runs.
    {:ok, _hits} = RAG.retrieve(scope, dataset.id, "zzz unrelated")
    refute_received {:expanded, _query}

    {:ok, dataset} = RAG.update_dataset(scope, dataset, %{"query_expansion" => true})

    {:ok, hits} = RAG.retrieve(scope, dataset.id, "zzz unrelated")
    assert_received {:expanded, "zzz unrelated"}
    assert Enum.any?(hits, &(&1.content =~ "paprika"))
  end

  test "retrieval evals score golden cases with hit rate and MRR", %{
    scope: scope,
    dataset: dataset
  } do
    ingest!(scope, dataset, "vacation.md", "Vacation policy: employees receive 25 paid days.")
    ingest!(scope, dataset, "shipping.md", "Shipping takes 3 to 5 business days by ground.")

    {:ok, _} =
      RAG.add_retrieval_case(scope, dataset, %{
        "question" => "how many vacation days do we get?",
        "expected" => "25 paid days"
      })

    {:ok, _} =
      RAG.add_retrieval_case(scope, dataset, %{
        "question" => "when does the office open?",
        "expected" => "text that appears nowhere at all"
      })

    assert [_case_a, _case_b] = RAG.list_retrieval_cases(scope, dataset.id)

    summary = RAG.evaluate_retrieval(scope, dataset.id)
    assert summary.total == 2
    assert summary.hits == 1
    assert summary.hit_rate == 0.5

    hit = Enum.find(summary.results, &(&1.expected == "25 paid days"))
    assert hit.rank >= 1
    assert summary.mrr > 0.0

    # Blank cases are refused; deletes narrow the set.
    assert {:error, _changeset} = RAG.add_retrieval_case(scope, dataset, %{"question" => "x"})
    [first | _] = RAG.list_retrieval_cases(scope, dataset.id)
    {:ok, _} = RAG.delete_retrieval_case(scope, first.id)
    assert length(RAG.list_retrieval_cases(scope, dataset.id)) == 1
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

  test "crawl_from_url ingests same-host linked pages, depth 1", %{
    scope: scope,
    dataset: dataset
  } do
    Application.put_env(:flux_rag, :req_options, plug: {Req.Test, Flux.RAGCrawlStub})
    on_exit(fn -> Application.delete_env(:flux_rag, :req_options) end)

    Req.Test.stub(Flux.RAGCrawlStub, fn conn ->
      body =
        case conn.request_path do
          "/docs" ->
            """
            <html><body><p>Index page.</p>
            <a href="/docs/setup">Setup</a>
            <a href="/docs/faq#top">FAQ</a>
            <a href="/docs/faq">FAQ again</a>
            <a href="https://elsewhere.example.net/offsite">Offsite</a>
            <a href="/docs">Self</a>
            </body></html>
            """

          "/docs/setup" ->
            "<html><body><p>Setup steps here.</p></body></html>"

          "/docs/faq" ->
            "<html><body><p>Frequently asked.</p></body></html>"
        end

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, body)
    end)

    {:ok, %{added: 3, skipped: 0}} =
      RAG.crawl_from_url(scope, dataset, "https://example.com/docs")

    names = RAG.list_documents(scope, dataset.id) |> Enum.map(& &1.name) |> Enum.sort()
    # Root + two distinct same-host links; offsite, self, and the
    # fragment-duplicate never ingest.
    assert names == ["example.com/docs", "example.com/docs/faq", "example.com/docs/setup"]
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

  test "auto-sync sweep enqueues due datasets only", %{scope: scope, dataset: dataset} do
    feed = """
    <rss version="2.0"><channel>
      <item><title>Auto post</title><guid>auto-1</guid>
      <description>Automatic ingestion works.</description></item>
    </channel></rss>
    """

    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.AutoSyncStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    Req.Test.stub(Flux.AutoSyncStub, fn conn -> Plug.Conn.send_resp(conn, 200, feed) end)

    :ok = Flux.Tools.install_plugin(scope, "rss")

    {:ok, _credential} =
      Flux.Providers.upsert_credential(scope, "rss", %{
        "feed_url" => "https://feeds.example.com/auto.xml"
      })

    {:ok, dataset} =
      RAG.update_dataset(scope, dataset, %{
        "sync_plugin_id" => "rss",
        "sync_interval_minutes" => 15
      })

    # Never synced → due immediately; the sweep enqueues and stamps.
    assert :ok = Flux.RAG.SyncSweepWorker.perform(%Oban.Job{args: %{}})
    Oban.drain_queue(queue: :ingest, with_recursion: true)

    assert [%{name: "Auto post", status: :ready}] = RAG.list_documents(scope, dataset.id)

    synced = RAG.get_dataset(scope, dataset.id)
    assert synced.last_synced_at

    # Within the interval nothing is enqueued again.
    assert :ok = Flux.RAG.SyncSweepWorker.perform(%Oban.Job{args: %{}})

    assert Oban.drain_queue(queue: :ingest, with_recursion: true) == %{
             cancelled: 0,
             discard: 0,
             failure: 0,
             snoozed: 0,
             success: 0
           }

    # Clearing the plugin clears the schedule.
    {:ok, cleared} = RAG.update_dataset(scope, synced, %{"sync_plugin_id" => ""})
    assert cleared.sync_plugin_id == nil
    assert cleared.sync_interval_minutes == nil
  end

  test "dataset retrieval settings set the default top_k and threshold", %{
    scope: scope,
    dataset: dataset
  } do
    ingest!(scope, dataset, "a.md", "Vacation policy: 25 paid vacation days per year.")
    ingest!(scope, dataset, "b.md", "Vacation requests go through the HR portal.")
    ingest!(scope, dataset, "c.md", "The dishwasher schedule is on the fridge.")

    # Default: 4 → all three match-ish rows can come back.
    {:ok, hits} = RAG.retrieve(scope, dataset.id, "vacation days")
    assert length(hits) >= 2

    # Per-dataset top_k caps the default; explicit opt still wins.
    {:ok, dataset} = RAG.update_dataset(scope, dataset, %{"retrieval_top_k" => 1})
    {:ok, [only]} = RAG.retrieve(scope, dataset.id, "vacation days")
    assert only.document.name == "a.md"
    {:ok, hits} = RAG.retrieve(scope, dataset.id, "vacation days", top_k: 3)
    assert length(hits) >= 2

    # An impossible threshold filters everything out.
    {:ok, _dataset} =
      RAG.update_dataset(scope, dataset, %{"retrieval_top_k" => "", "score_threshold" => 0.99})

    assert {:ok, []} = RAG.retrieve(scope, dataset.id, "vacation days")
  end

  test "segments can be edited, disabled, and deleted", %{scope: scope, dataset: dataset} do
    document = ingest!(scope, dataset, "policy.md", "Vacation policy: 20 paid days per year.")
    [segment] = RAG.list_segments(scope, document.id)

    # Edit + re-embed: retrieval sees the corrected text.
    {:ok, updated} =
      RAG.update_segment(scope, segment.id, "Vacation policy: 25 paid days per year.")

    assert updated.content =~ "25 paid days"
    assert updated.embedding != segment.embedding

    {:ok, [hit]} = RAG.retrieve(scope, dataset.id, "how many vacation days?")
    assert hit.content =~ "25 paid days"

    # Empty edits are refused.
    assert {:error, :empty} = RAG.update_segment(scope, segment.id, "   ")

    # Disabled → out of retrieval; enabled → back in.
    {:ok, _} = RAG.set_segment_enabled(scope, segment.id, false)
    assert {:ok, []} = RAG.retrieve(scope, dataset.id, "how many vacation days?")

    {:ok, _} = RAG.set_segment_enabled(scope, segment.id, true)
    assert {:ok, [_hit]} = RAG.retrieve(scope, dataset.id, "how many vacation days?")

    # Delete removes the row and keeps the document's count honest.
    {:ok, _} = RAG.delete_segment(scope, segment.id)
    assert RAG.list_segments(scope, document.id) == []

    refreshed = Flux.Repo.get!(Flux.RAG.Document, document.id, skip_workspace_guard: true)
    assert refreshed.segment_count == 0
  end

  test "indexing extracts entities and retrieval uses the mention graph", %{
    scope: scope,
    dataset: dataset
  } do
    ingest!(scope, dataset, "acme.md", """
    Acme Corp manufactures anvils in Toledo. Wile Coyote is the best
    customer of Acme Corp and orders monthly.
    """)

    ingest!(scope, dataset, "initech.md", """
    Initech ships TPS report software. Bill Lumbergh runs Initech.
    """)

    # Entities landed with mention counts.
    entities = RAG.list_entities(scope, dataset.id)
    names = Enum.map(entities, & &1.name)
    assert "acme corp" in names
    assert "initech" in names
    assert "wile coyote" in names

    # Co-occurrence: Wile Coyote shares a segment with Acme Corp, not Initech.
    related = RAG.related_entities(scope, dataset.id, "Acme Corp")
    related_names = Enum.map(related, & &1.name)
    assert "wile coyote" in related_names
    refute "bill lumbergh" in related_names

    # An entity-bearing query retrieves the segment that mentions it first.
    {:ok, [top | _rest]} = RAG.retrieve(scope, dataset.id, "who buys from Acme Corp?")
    assert top.document.name == "acme.md"

    # Re-indexing does not duplicate entities.
    {:ok, _count} = RAG.reindex_dataset(scope, dataset)
    Oban.drain_queue(queue: :ingest)

    assert RAG.list_entities(scope, dataset.id) |> Enum.map(& &1.name) |> Enum.uniq() ==
             RAG.list_entities(scope, dataset.id) |> Enum.map(& &1.name)
  end

  test "LLM entity extraction uses the bound model, falls back on errors", %{
    scope: scope,
    dataset: dataset
  } do
    {:ok, dataset} =
      RAG.update_dataset(scope, dataset, %{
        "entity_plugin_id" => "openai",
        "entity_model" => "gpt-4o"
      })

    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.EntityStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)

    # The model returns entities the heuristic could never find (lowercase).
    Req.Test.stub(Flux.EntityStub, fn conn ->
      frame = ~s({"choices":[{"delta":{"content":"[\\"quantum flux drive\\", \\"zorblax\\"]"}}]})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: #{frame}\n\ndata: [DONE]\n\n")
    end)

    ingest!(scope, dataset, "sci.md", "the quantum flux drive was patented by zorblax in 2140")

    names = RAG.list_entities(scope, dataset.id) |> Enum.map(& &1.name)
    assert "quantum flux drive" in names
    assert "zorblax" in names

    # A failing model degrades to the heuristic instead of failing indexing.
    Req.Test.stub(Flux.EntityStub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    document = ingest!(scope, dataset, "acme.md", "Acme Corp still ships anvils.")
    assert document.status == :ready

    names = RAG.list_entities(scope, dataset.id) |> Enum.map(& &1.name)
    assert "acme corp" in names
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
