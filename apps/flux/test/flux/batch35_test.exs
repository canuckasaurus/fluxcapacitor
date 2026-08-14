defmodule Flux.Batch35Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch35 WS"})
    scope = Accounts.scope_for(account)

    %{account: account, scope: scope, workspace: workspace}
  end

  describe "visitor identity" do
    test "stores trimmed name and validated email", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "ID App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_x"})

      {:ok, updated} =
        Chat.set_visitor_identity(scope, conversation.id, "  Doc Brown  ", "doc@example.com")

      assert updated.visitor_name == "Doc Brown"
      assert updated.visitor_email == "doc@example.com"

      # A bad email is ignored, not stored.
      {:ok, updated} = Chat.set_visitor_identity(scope, conversation.id, "", "not-an-email")
      assert updated.visitor_email == "doc@example.com"
    end
  end

  describe "handoff assignment" do
    test "claim and release", %{account: account, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Handoff App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_y"})
      {:ok, _flagged} = Chat.request_handoff(scope, app, conversation.id)

      {:ok, claimed} = Chat.assign_handoff(scope, conversation.id, account.id)
      assert claimed.assigned_account_id == account.id
      assert claimed.assigned_account.email == account.email

      [queued] = Chat.handoff_queue(scope, app.id)
      assert queued.assigned_account.email == account.email

      {:ok, released} = Chat.assign_handoff(scope, conversation.id, nil)
      assert released.assigned_account_id == nil
    end
  end

  describe "scheduled publish" do
    test "schedules, refuses the past, and the tick publishes", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Timed Flux"})

      graph =
        update_in(workflow.graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")

            node ->
              node
          end)
        end)

      {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)

      past = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      assert {:error, :in_the_past} = Workflows.schedule_publish(scope, workflow, past)

      future = DateTime.add(DateTime.utc_now(:second), 1, :hour)
      {:ok, scheduled} = Workflows.schedule_publish(scope, workflow, future)
      assert scheduled.publish_at == future

      # Not due yet: nothing happens.
      assert :ok = Workflows.run_scheduled_publishes(DateTime.utc_now(:second))
      assert Workflows.serving_version(scope, scheduled) == nil

      # Due: the tick publishes and clears the schedule.
      assert :ok = Workflows.run_scheduled_publishes(DateTime.add(future, 1, :minute))
      version = Workflows.serving_version(scope, scheduled)
      assert version.version == 1
      assert version.note =~ "scheduled"

      reloaded = Workflows.get_workflow(scope, workflow.id)
      assert reloaded.publish_at == nil
    end
  end

  describe "search_conversation_titles" do
    test "matches by title, workspace-wide", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Palette App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      Chat.create_conversation(scope, app, %{title: "Flux capacitor overheating"})
      Chat.create_conversation(scope, app, %{title: "Something else"})

      assert [found] = Chat.search_conversation_titles(scope, "capacitor")
      assert found.title == "Flux capacitor overheating"
      assert Chat.search_conversation_titles(scope, "zzz-no-match") == []
    end
  end
end
