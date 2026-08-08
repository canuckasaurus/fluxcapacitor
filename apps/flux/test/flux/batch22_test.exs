defmodule Flux.Batch22Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.ConversationEvals

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch22 WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Echo App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{scope: scope, app: app, workspace: workspace, account: account}
  end

  describe "chat-app model A/B" do
    test "a 100% split stamps every reply as variant b", %{scope: scope, app: app} do
      {:ok, app} =
        Chat.update_app(scope, app, %{
          "ab_provider_plugin_id" => "echo",
          "ab_model" => "echo-challenger",
          "ab_split" => 100
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hello")
      assert_receive {:done, reply}, 5_000

      assert reply.usage["variant"] == "b"
      assert reply.usage["model_used"] == "echo/echo-challenger"
    end

    test "a 0% split never runs the challenger", %{scope: scope, app: app} do
      {:ok, app} =
        Chat.update_app(scope, app, %{
          "ab_provider_plugin_id" => "echo",
          "ab_model" => "echo-challenger",
          "ab_split" => 0
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hello")
      assert_receive {:done, reply}, 5_000

      refute reply.usage["variant"]
    end

    test "splits outside 0..100 are refused", %{scope: scope, app: app} do
      assert {:error, %Ecto.Changeset{}} = Chat.update_app(scope, app, %{"ab_split" => 101})
    end

    test "app_ab_stats aggregates replies, feedback, and tokens per variant", %{
      scope: scope,
      app: app
    } do
      {:ok, app} =
        Chat.update_app(scope, app, %{
          "ab_provider_plugin_id" => "echo",
          "ab_model" => "echo-challenger",
          "ab_split" => 100
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hello")
      assert_receive {:done, reply}, 5_000

      {:ok, _liked} = Chat.set_feedback(scope, reply.id, :like)

      stats = Chat.app_ab_stats(scope, app.id)
      assert stats["b"].replies == 1
      assert stats["b"].likes == 1
      assert stats["b"].tokens > 0
      assert stats["a"].replies == 0
    end
  end

  describe "conversation evals" do
    defp put_judge(reply) do
      Application.put_env(:flux, :eval_judge, fn _workspace_id, _messages -> {:ok, reply} end)
      on_exit(fn -> Application.delete_env(:flux, :eval_judge) end)
    end

    test "creation requires a name, an expectation, and at least one turn", %{
      scope: scope,
      app: app
    } do
      assert {:error, changeset} =
               ConversationEvals.create_conversation_eval(scope, app, %{
                 "name" => "empty",
                 "expectation" => "anything",
                 "turns" => ["", "  "]
               })

      assert %{turns: [_reason]} = errors_on(changeset)

      assert {:ok, eval} =
               ConversationEvals.create_conversation_eval(scope, app, %{
                 "name" => "greeting",
                 "expectation" => "stays polite",
                 "turns" => ["hi there", "", "and again"]
               })

      assert eval.turns == ["hi there", "and again"]
    end

    test "run plays the turns and stores the judged score and transcript", %{
      scope: scope,
      app: app
    } do
      put_judge(~s({"score": 0.9, "reason": "polite throughout"}))

      {:ok, eval} =
        ConversationEvals.create_conversation_eval(scope, app, %{
          "name" => "greeting",
          "expectation" => "answers every turn",
          "turns" => ["first question", "second question"]
        })

      assert {:ok, ran} = ConversationEvals.run_conversation_eval(scope, eval.id)
      assert ran.last_score == 0.9
      assert ran.last_reason == "polite throughout"
      assert ran.last_run_at

      assert [
               %{"role" => "user", "content" => "first question"},
               %{"role" => "assistant", "content" => first_reply},
               %{"role" => "user", "content" => "second question"},
               %{"role" => "assistant", "content" => _second_reply}
             ] = ran.last_transcript

      assert first_reply =~ "first question"
    end

    test "a score drop raises an eval_regressed notification", %{scope: scope, app: app} do
      put_judge(~s({"score": 0.9, "reason": "good"}))

      {:ok, eval} =
        ConversationEvals.create_conversation_eval(scope, app, %{
          "name" => "drifting",
          "expectation" => "keeps the persona",
          "turns" => ["one turn"]
        })

      {:ok, _first} = ConversationEvals.run_conversation_eval(scope, eval.id)

      Application.put_env(:flux, :eval_judge, fn _workspace_id, _messages ->
        {:ok, ~s({"score": 0.2, "reason": "persona lost"})}
      end)

      {:ok, second} = ConversationEvals.run_conversation_eval(scope, eval.id)
      assert second.last_score == 0.2

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      assert Enum.any?(titles, &(&1 =~ "Conversation eval \"drifting\" regressed"))
    end

    test "delete removes the eval", %{scope: scope, app: app} do
      {:ok, eval} =
        ConversationEvals.create_conversation_eval(scope, app, %{
          "name" => "gone",
          "expectation" => "n/a",
          "turns" => ["hello"]
        })

      assert {:ok, _deleted} = ConversationEvals.delete_conversation_eval(scope, eval.id)
      assert ConversationEvals.list_conversation_evals(scope, app.id) == []
    end
  end

  describe "session device info" do
    test "session tokens record ip and a truncated user agent", %{account: account} do
      token =
        Accounts.generate_account_session_token(account, %{
          ip: "203.0.113.9",
          user_agent: String.duplicate("VeryLongAgent ", 30)
        })

      record =
        Flux.Repo.get_by!(Flux.Accounts.AccountToken, token: token, context: "session")

      assert record.ip == "203.0.113.9"
      assert String.length(record.user_agent) == 250
    end

    test "device info stays optional", %{account: account} do
      token = Accounts.generate_account_session_token(account)
      record = Flux.Repo.get_by!(Flux.Accounts.AccountToken, token: token, context: "session")
      assert record.ip == nil
      assert record.user_agent == nil
    end
  end
end
