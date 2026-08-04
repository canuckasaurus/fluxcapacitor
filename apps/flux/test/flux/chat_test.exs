defmodule Flux.ChatTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Providers

  # Core tests run against Flux.FakeRuntime (see test_helper.exs); the real
  # runtime path is exercised end-to-end by the flux_web suites.
  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Chat WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Echo App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "system_prompt" => "You echo."
      })

    %{scope: scope, app: app, workspace: workspace}
  end

  test "send_message streams chunks and persists the final message", %{scope: scope, app: app} do
    conversation = Chat.create_conversation(scope, app)

    {:ok, user_message, assistant_message} =
      Chat.send_message(scope, app, conversation, "hello flux")

    assert user_message.role == :user
    assert assistant_message.status == :streaming

    assert_receive {:chunk, _delta}, 2_000
    assert_receive {:done, final}, 5_000

    assert final.id == assistant_message.id
    assert final.status == :completed
    assert final.content =~ "You said: hello flux"
    assert final.usage["output_tokens"] == 12

    messages = Chat.list_messages(scope, conversation.id)
    assert length(messages) == 2
  end

  test "regenerate discards the last reply and streams a fresh one", %{
    scope: scope,
    app: app
  } do
    conversation = Chat.create_conversation(scope, app)

    # Nothing to regenerate before any reply exists.
    assert {:error, :nothing_to_regenerate} = Chat.regenerate(scope, app, conversation)

    {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "take one")
    assert_receive {:done, first_reply}, 5_000

    {:ok, replacement} = Chat.regenerate(scope, app, conversation)
    assert replacement.status == :streaming
    assert replacement.id != first_reply.id

    assert_receive {:done, final}, 5_000
    assert final.id == replacement.id
    assert final.content =~ "You said: take one"

    # Still exactly one user + one assistant message — the old reply is gone.
    messages = Chat.list_messages(scope, conversation.id)
    assert Enum.map(messages, & &1.role) == [:user, :assistant]
    refute Enum.any?(messages, &(&1.id == first_reply.id))
  end

  test "export_finetune builds JSONL from liked replies and annotations", %{
    scope: scope,
    app: app
  } do
    conversation = Chat.create_conversation(scope, app)

    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "liked question")
    assert_receive {:done, liked_reply}, 5_000
    {:ok, _} = Chat.set_feedback(scope, liked_reply.id, :like)

    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "unrated question")
    assert_receive {:done, _unrated}, 5_000

    {:ok, _annotation} =
      Chat.create_annotation(scope, app, %{question: "canned?", answer: "Absolutely."})

    {:ok, jsonl} = Chat.export_finetune(scope, app.id)
    lines = jsonl |> String.split("\n") |> Enum.map(&Jason.decode!/1)

    assert length(lines) == 2

    assert Enum.any?(lines, fn %{"messages" => messages} ->
             match?(
               [
                 %{"role" => "system", "content" => "You echo."},
                 %{"role" => "user", "content" => "liked question"},
                 %{"role" => "assistant", "content" => _reply}
               ],
               messages
             )
           end)

    assert Enum.any?(lines, fn %{"messages" => messages} ->
             Enum.any?(messages, &(&1["content"] == "Absolutely."))
           end)

    # :all includes the unrated pair too.
    {:ok, jsonl_all} = Chat.export_finetune(scope, app.id, filter: :all)
    assert length(String.split(jsonl_all, "\n")) == 3
  end

  test "the first question titles the conversation, renames stick", %{scope: scope, app: app} do
    conversation = Chat.create_conversation(scope, app)
    long = String.duplicate("where is my very large order number 12345? ", 4)

    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, long)
    assert_receive {:done, _final}, 5_000

    titled = Chat.get_conversation(scope, conversation.id)
    assert String.length(titled.title) <= 60
    assert titled.title =~ "where is my very large order"
    assert String.ends_with?(titled.title, "…")

    # Later messages never retitle; explicit renames survive too.
    {:ok, _} = Chat.rename_conversation(scope, conversation.id, "Order 12345")
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "second question")
    assert_receive {:done, _final}, 5_000
    assert Chat.get_conversation(scope, conversation.id).title == "Order 12345"
  end

  test "conversation history feeds the next turn", %{scope: scope, app: app} do
    conversation = Chat.create_conversation(scope, app)

    {:ok, _, _} = Chat.send_message(scope, app, conversation, "first")
    assert_receive {:done, _}, 5_000

    {:ok, _, _} = Chat.send_message(scope, app, conversation, "second")
    assert_receive {:done, final}, 5_000

    # Echo answers the LAST user message — proves history ordering held.
    assert final.content =~ "You said: second"
    assert length(Chat.list_messages(scope, conversation.id)) == 4
  end

  test "apps are workspace-scoped", %{app: app} do
    other = account_fixture()
    {:ok, _} = Accounts.create_workspace(other, %{name: "Other"})
    other_scope = Accounts.scope_for(other)

    assert Chat.list_apps(other_scope) == []
    assert {:error, :not_found} = Chat.get_app(other_scope, app.id)
  end

  test "create_app requires app_create_and_management", %{scope: scope, app: app} do
    member = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: app.workspace_id,
        account_id: member.id,
        role: :normal
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, app.workspace_id)
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} =
             Chat.create_app(member_scope, %{
               "name" => "Nope",
               "provider_plugin_id" => "echo",
               "model" => "echo-1"
             })

    # But an editor-created scope (the owner here) can — sanity check.
    assert {:ok, _} =
             Chat.create_app(scope, %{
               "name" => "Second",
               "provider_plugin_id" => "echo",
               "model" => "echo-1"
             })
  end

  test "api tokens roundtrip and resolve to the app", %{scope: scope, app: app} do
    {:ok, token, raw} = Chat.create_api_token(scope, app)
    assert String.starts_with?(raw, "app-")
    assert token.prefix =~ "app-"

    assert {:ok, resolved_app, _token} = Chat.fetch_app_by_token(raw)
    assert resolved_app.id == app.id

    assert {:error, :invalid_token} = Chat.fetch_app_by_token("app-bogus")
    assert {:error, :invalid_token} = Chat.fetch_app_by_token("nonsense")

    {:ok, _} = Chat.revoke_api_token(scope, token.id)
    assert {:error, :invalid_token} = Chat.fetch_app_by_token(raw)
  end

  test "stopping mid-stream persists the streamed prefix", %{scope: scope} do
    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Drip App",
        "provider_plugin_id" => "drip",
        "model" => "echo-1"
      })

    conversation = Chat.create_conversation(scope, app)
    {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "go")

    # Wait until the prefix has streamed, then stop while the provider hangs.
    assert_receive {:chunk, "Dripped "}, 2_000
    assert_receive {:chunk, "prefix"}, 2_000

    assert {:ok, stopped} = Chat.stop_generation(scope, assistant.id)
    assert stopped.status == :stopped
    assert stopped.content == "Dripped prefix"
  end

  test "available_models includes keyless echo without credentials", %{scope: scope} do
    models = Providers.available_models(scope)
    assert Enum.any?(models, &(&1.plugin_id == "echo" and &1.model.name == "echo-1"))
    refute Enum.any?(models, &(&1.plugin_id == "openai"))
  end

  test "daily token quota refuses sends once spent", %{scope: scope, app: app} do
    {:ok, app} = Chat.update_app(scope, app, %{"daily_token_limit" => 10})
    conversation = Chat.create_conversation(scope, app)

    # First message goes through (0 tokens used so far) and records usage.
    {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hello")
    assert_receive {:done, final}, 5_000
    assert final.usage["output_tokens"] > 0

    # Echo replies record 12 output tokens — over the 10-token budget now.
    assert {:error, :quota_exceeded} = Chat.send_message(scope, app, conversation, "again")

    # Lifting the limit unblocks.
    {:ok, app} = Chat.update_app(scope, app, %{"daily_token_limit" => nil})
    assert {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "again")
    assert_receive {:done, _final}, 5_000
  end

  describe "advanced_chat (chatflow) apps" do
    setup %{scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Chatflow Flux"})

      # Echo LLM + an assigner that records the last question as a
      # conversation variable.
      graph =
        workflow.graph
        |> update_in(["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")
              |> put_in(["config", "prompt"], "{{sys.query}}")

            node ->
              node
          end)
        end)
        |> Map.update!("nodes", fn nodes ->
          nodes ++
            [
              %{
                "id" => "assign_1",
                "type" => "variable_assigner",
                "title" => "Remember",
                "position" => %{"x" => 900, "y" => 400},
                "config" => %{
                  "assignments" => [%{"name" => "last_question", "value" => "{{sys.query}}"}]
                }
              }
            ]
        end)
        |> Map.update!("edges", fn edges ->
          edges ++
            [
              %{
                "id" => "e_answer_assign",
                "source" => "answer_1",
                "source_handle" => "default",
                "target" => "assign_1"
              }
            ]
        end)

      {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
      {:ok, _version} = Flux.Workflows.publish(scope, workflow)

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Chatflow App",
          "mode" => "advanced_chat",
          "workflow_id" => workflow.id
        })

      %{chatflow_app: app, workflow: workflow}
    end

    test "a turn runs the published flux and persists conversation variables", %{
      scope: scope,
      chatflow_app: app
    } do
      conversation = Chat.create_conversation(scope, app)

      {:ok, _user, assistant_message} =
        Chat.send_message(scope, app, conversation, "what is flux?")

      assert_receive {:done, final}, 5_000
      assert final.id == assistant_message.id
      assert final.content =~ "You said: what is flux?"

      updated = Flux.Repo.get!(Chat.Conversation, conversation.id, skip_workspace_guard: true)
      assert updated.variables == %{"last_question" => "what is flux?"}
    end

    test "chatflow replies carry documents generated by the flux", %{scope: scope} do
      document = """
      <?xml version="1.0"?>
      <w:document xmlns:w="wns"><w:body>\
      <w:p><w:r><w:t>Letter about {{ sys.query }}</w:t></w:r></w:p>\
      </w:body></w:document>
      """

      {:ok, {_name, docx}} =
        :zip.create(~c"t.docx", [{~c"word/document.xml", document}], [:memory])

      {:ok, template} =
        Flux.DocTemplates.create_docx(scope, %{binary: docx, name: "Reply letter"})

      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Letter Chatflow"})

      graph =
        workflow.graph
        |> update_in(["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")
              |> put_in(["config", "prompt"], "{{sys.query}}")

            node ->
              node
          end)
        end)
        |> Map.update!("nodes", fn nodes ->
          nodes ++
            [
              %{
                "id" => "doc_1",
                "type" => "document",
                "title" => "Letter",
                "position" => %{"x" => 900, "y" => 400},
                "config" => %{"template_id" => template.id}
              }
            ]
        end)
        |> Map.update!("edges", fn edges ->
          edges ++
            [
              %{
                "id" => "e_answer_doc",
                "source" => "answer_1",
                "source_handle" => "default",
                "target" => "doc_1"
              }
            ]
        end)

      {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
      {:ok, _version} = Flux.Workflows.publish(scope, workflow)

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Letter App",
          "mode" => "advanced_chat",
          "workflow_id" => workflow.id
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "the lease")
      assert_receive {:done, final}, 5_000

      assert [%{"name" => "Reply letter.docx", "url" => "/files/file_" <> _t}] =
               final.usage["files"]
    end

    test "topic clusters group similar questions deterministically", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Topics App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      questions = [
        "how do refunds work for orders",
        "refunds question about my orders",
        "can I get refunds on recent orders",
        "shipping delivery estimate please",
        "what is the shipping delivery time"
      ]

      for question <- questions do
        conversation = Chat.create_conversation(scope, app)
        {:ok, _u, _a} = Chat.send_message(scope, app, conversation, question)
        assert_receive {:done, _reply}, 5_000
      end

      clusters = Chat.topic_clusters(scope, app.id)
      assert length(clusters) == 2

      [biggest, second] = clusters
      assert biggest.count == 3
      assert biggest.name =~ "refunds"
      assert second.count == 2
      assert second.name =~ "shipping"
      assert is_binary(biggest.example)
    end

    test "file_output files ride chatflow replies as download chips too", %{scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Report Chatflow"})

      graph =
        workflow.graph
        |> update_in(["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")
              |> put_in(["config", "prompt"], "{{sys.query}}")

            node ->
              node
          end)
        end)
        |> Map.update!("nodes", fn nodes ->
          nodes ++
            [
              %{
                "id" => "file_1",
                "type" => "file_output",
                "title" => "Report",
                "position" => %{"x" => 900, "y" => 400},
                "config" => %{
                  "format" => "markdown",
                  "content" => "# {{sys.query}}",
                  "output_name" => "chat-report"
                }
              }
            ]
        end)
        |> Map.update!("edges", fn edges ->
          edges ++
            [
              %{
                "id" => "e_answer_file",
                "source" => "answer_1",
                "source_handle" => "default",
                "target" => "file_1"
              }
            ]
        end)

      {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
      {:ok, _version} = Flux.Workflows.publish(scope, workflow)

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Report App",
          "mode" => "advanced_chat",
          "workflow_id" => workflow.id
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "gigawatts")
      assert_receive {:done, final}, 5_000

      assert [%{"name" => "chat-report.md", "url" => "/files/file_" <> _t}] =
               final.usage["files"]
    end

    test "chatflow turns see prior history as {{sys.history}}", %{scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Memory Flux"})

      graph =
        update_in(workflow.graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")
              |> put_in(["config", "prompt"], "[{{sys.history}}] {{sys.query}}")

            node ->
              node
          end)
        end)

      {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
      {:ok, _version} = Flux.Workflows.publish(scope, workflow)

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Memory App",
          "mode" => "advanced_chat",
          "workflow_id" => workflow.id
        })

      conversation = Chat.create_conversation(scope, app)

      {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "first question")
      assert_receive {:done, first}, 5_000
      # First turn has no history.
      assert first.content =~ "You said: [] first question"

      {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "second question")
      assert_receive {:done, second}, 5_000
      assert second.content =~ "user: first question"
      assert second.content =~ "assistant:"
      assert second.content =~ "second question"
    end

    test "creating a chatflow app requires a flux", %{scope: scope} do
      assert {:error, changeset} =
               Chat.create_app(scope, %{"name" => "No Flux", "mode" => "advanced_chat"})

      assert %{workflow_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "an unpublished flux fails the turn gracefully", %{scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Unpublished"})

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Broken Chatflow",
          "mode" => "advanced_chat",
          "workflow_id" => workflow.id
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hi")

      assert_receive {:error, message}, 5_000
      assert message.error =~ "no published flux"
    end
  end
end
