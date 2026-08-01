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
