defmodule Flux.Batch21Test do
  @moduledoc "Batch-21 context features: batch concurrency, chatflow memory, conversations in export, audio, embeddings."
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "B21 WS"})
    scope = Accounts.scope_for(account)
    %{account: account, scope: scope, workspace: workspace}
  end

  defp echo_graph do
    %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "config" => %{
            "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "llm_1",
          "type" => "llm",
          "title" => "LLM",
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "prompt" => "{{start.query}}"
          }
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "config" => %{"answer" => "{{llm_1.text}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "llm_1"},
        %{"id" => "e2", "source" => "llm_1", "source_handle" => "default", "target" => "answer_1"}
      ]
    }
  end

  test "parallel batches complete every row", %{scope: scope} do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Parallel Flux"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    rows = for index <- 1..8, do: %{"query" => "row #{index}"}
    {:ok, batch} = Workflows.start_batch(scope, workflow, rows, name: "par.csv", concurrency: 4)
    assert batch.concurrency == 4

    :ok = Workflows.perform_batch(batch.id)

    finished = Workflows.get_batch(scope, batch.id)
    assert finished.status == :completed
    assert finished.succeeded == 8
    assert finished.failed == 0

    # Over-asking is capped at 8.
    {:ok, capped} = Workflows.start_batch(scope, workflow, rows, name: "cap.csv", concurrency: 99)
    assert capped.concurrency == 8
  end

  test "per-node timeout_ms fails a stalling node honestly", %{scope: scope} do
    slow_graph =
      update_in(echo_graph(), ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node ->
            node
            |> put_in(["config", "provider_plugin_id"], "drip")
            |> put_in(["config", "model"], "drip-1")
            |> put_in(["config", "timeout_ms"], 1_000)

          node ->
            node
        end)
      end)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Slow Flux"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, slow_graph)

    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "wait"})
    assert_receive {:run_finished, finished}, 10_000
    assert finished.status == :failed
    assert finished.error =~ "timed out after 1000ms"
  end

  test "long chatflow conversations fold a summary into sys.history", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Memory Chatflow"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _version} = Workflows.publish(scope, workflow)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Memory App",
        "mode" => "advanced_chat",
        "workflow_id" => workflow.id
      })

    # The default model summarizes for chatflows (they bind no provider).
    {:ok, _} = Flux.Providers.set_default_model(scope, "echo", "echo-1")

    conversation = Chat.create_conversation(scope, app)
    filler = String.duplicate("The flux capacitor hums along nicely. ", 40)

    for index <- 1..30 do
      Repo.insert!(%Flux.Chat.Message{
        workspace_id: workspace.id,
        conversation_id: conversation.id,
        role: (rem(index, 2) == 1 && :user) || :assistant,
        content: "Turn #{index}: #{filler}",
        status: :completed
      })
    end

    {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "still with me?")
    assert_receive {:done, final}, 10_000
    assert final.status == :completed

    folded = Repo.get!(Flux.Chat.Conversation, conversation.id, skip_workspace_guard: true)
    assert is_binary(folded.summary) and folded.summary != ""
    assert folded.summarized_seq > 0
  end

  test "workspace export round-trips conversations", %{scope: scope, account: account} do
    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "History App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    conversation = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "remember me")
    assert_receive {:done, _}, 5_000
    {:ok, _} = Chat.set_conversation_labels(scope, conversation.id, ["archived-test"])

    {:ok, payload} = Flux.Export.workspace(scope)
    [app_entry] = payload["apps"]
    assert [conversation_entry] = app_entry["conversations"]
    assert Enum.any?(conversation_entry["messages"], &(&1["content"] == "remember me"))
    assert conversation_entry["labels"] == ["archived-test"]

    # Import into a fresh workspace restores the transcript.
    {:ok, {_second, _}} = Accounts.create_workspace(account, %{name: "B21 Restore"})
    fresh_scope = Accounts.scope_for(Repo.get!(Flux.Accounts.Account, account.id))
    assert fresh_scope.workspace.name == "B21 Restore"

    {:ok, _counts} = Flux.Import.workspace(fresh_scope, Jason.encode!(payload))

    [restored_app] = Chat.list_apps(fresh_scope)
    [restored_conversation] = Chat.list_conversations(fresh_scope, restored_app.id)
    assert restored_conversation.labels == ["archived-test"]

    messages = Chat.list_messages(fresh_scope, restored_conversation.id)
    assert Enum.any?(messages, &(&1.content == "remember me"))
  end

  test "audio transcribes through the workspace default provider", %{
    scope: scope,
    workspace: workspace
  } do
    assert {:error, :not_supported} = Flux.Providers.transcribe(workspace.id, <<1, 2, 3>>)

    {:ok, _} = Flux.Providers.set_default_model(scope, "echo", "echo-1")

    assert {:ok, %{text: text}} = Flux.Providers.transcribe(workspace.id, <<1, 2, 3>>)
    assert text =~ "3 bytes of audio"
  end

  test "workspace embeddings resolve credentials per plugin", %{workspace: workspace} do
    assert {:ok, %{vectors: [vector], usage: usage}} =
             Flux.Providers.embed(workspace.id, "echo", "echo-embed", ["hello world"])

    assert length(vector) == 16
    assert usage[:input_tokens] == 0
  end
end
