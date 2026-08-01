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
