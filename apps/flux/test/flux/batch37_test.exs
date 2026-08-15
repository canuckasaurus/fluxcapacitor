defmodule Flux.Batch37Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures
  import Swoosh.TestAssertions

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch37 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B37 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  # The account fixture mails confirmation instructions; empty the
  # mailbox so email assertions see only what the test itself sends.
  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end

  defp wait_for_completion(message_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      case Flux.Repo.get!(Flux.Chat.Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end

  describe "message edit & retry" do
    test "rewrites the last user message and regenerates from it", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      {:ok, user_message, assistant} = Chat.send_message(scope, app, conversation, "first draft")
      wait_for_completion(assistant.id)

      {:ok, edited, new_assistant} =
        Chat.edit_message(scope, app, conversation, user_message.id, "second draft")

      assert edited.id == user_message.id
      assert edited.content == "second draft"

      done = wait_for_completion(new_assistant.id)
      assert done.status == :completed

      # The old reply is gone: exactly one user + one assistant message.
      messages = Chat.list_messages(scope, conversation.id)
      assert [%{role: :user, content: "second draft"}, %{role: :assistant}] = messages
    end

    test "only the last user message is editable", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      {:ok, first_user, assistant} = Chat.send_message(scope, app, conversation, "one")
      wait_for_completion(assistant.id)
      {:ok, _second_user, assistant2} = Chat.send_message(scope, app, conversation, "two")
      wait_for_completion(assistant2.id)

      assert {:error, :not_last} =
               Chat.edit_message(scope, app, conversation, first_user.id, "rewritten")

      assert {:error, :not_found} =
               Chat.edit_message(scope, app, conversation, Ecto.UUID.generate(), "ghost")
    end
  end

  describe "transcript email" do
    test "sends to the visitor's address; refuses without one", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_t"})
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "hello there")
      wait_for_completion(assistant.id)

      assert {:error, :no_email} = Chat.email_transcript(scope, app, conversation.id)
      drain_emails()

      {:ok, _updated} =
        Chat.set_visitor_identity(scope, conversation.id, "Doc", "doc@example.com")

      assert :ok = Chat.email_transcript(scope, app, conversation.id)

      assert_email_sent(fn email ->
        [{_name, to}] = email.to
        to == "doc@example.com" and email.text_body =~ "hello there"
      end)
    end
  end

  describe "new-device login alerts" do
    test "an unseen ip/browser pair alerts; the first session stays quiet", %{account: account} do
      drain_emails()
      Accounts.generate_account_session_token(account, %{ip: "10.0.0.1", user_agent: "Firefox/1"})
      refute_email_sent()

      Accounts.generate_account_session_token(account, %{ip: "10.0.0.1", user_agent: "Firefox/1"})
      refute_email_sent()

      Accounts.generate_account_session_token(account, %{ip: "203.0.113.9", user_agent: "Edg/9"})

      assert_email_sent(fn email ->
        email.subject =~ "New sign-in" and email.text_body =~ "203.0.113.9"
      end)
    end
  end

  describe "fire trigger" do
    test "starts a run through the trigger path", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Fired Flux"})

      {:ok, trigger} =
        Workflows.create_trigger(scope, workflow, %{
          "type" => "schedule",
          "interval_minutes" => 60,
          "inputs" => %{"note" => "manual"}
        })

      assert {:error, :not_published} = Workflows.fire_trigger(scope, trigger.id)

      {:ok, _version} = Workflows.publish(scope, workflow)
      assert {:ok, run} = Workflows.fire_trigger(scope, trigger.id)
      assert run.started_by == "trigger:schedule"

      # Let the async run settle before teardown.
      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        case Flux.Repo.get!(Flux.Workflows.WorkflowRun, run.id, skip_workspace_guard: true) do
          %{status: :running} -> Process.sleep(100) && {:cont, nil}
          settled -> {:halt, settled}
        end
      end)

      assert {:error, :not_found} = Workflows.fire_trigger(scope, Ecto.UUID.generate())
    end
  end

  describe "audit actor filter" do
    test "keeps one member's entries", %{scope: scope, workspace: workspace} do
      other = account_fixture()
      {:ok, _membership} = Accounts.scim_provision(workspace, other.email)

      Flux.Audit.record(scope, "flux.create", resource_type: "workflow")

      mine = Flux.Audit.list(scope, 100, actor_id: scope.account.id)
      assert Enum.any?(mine, &(&1.action == "flux.create"))
      assert Enum.all?(mine, &(&1.actor_id == scope.account.id))

      assert Flux.Audit.list(scope, 100, actor_id: other.id)
             |> Enum.all?(&(&1.actor_id == other.id))
    end
  end

  describe "daily usage" do
    test "buckets runs and chat replies by day", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "count my tokens")
      wait_for_completion(assistant.id)

      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Usage Flux"})

      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: Flux.Accounts.Scope.workspace_id(scope),
        workflow_id: workflow.id,
        status: :succeeded,
        usage: %{"input_tokens" => 100, "output_tokens" => 40, "estimated_cost_usd" => 0.002}
      })

      assert [today] = Flux.Usage.daily_usage(scope, 7)
      assert today.date == Date.utc_today()
      assert today.runs == 1
      assert today.messages == 1
      assert today.input_tokens >= 100
      assert today.output_tokens >= 40
      assert today.cost >= 0.002
    end
  end

  describe "workspace locale" do
    test "set, read, clear", %{scope: scope} do
      assert Accounts.workspace_locale(scope) == nil

      {:ok, _workspace} = Accounts.set_workspace_locale(scope, "de")
      scope = Accounts.scope_for(Accounts.get_account!(scope.account.id))
      assert Accounts.workspace_locale(scope) == "de"

      {:ok, _workspace} = Accounts.set_workspace_locale(scope, nil)
      scope = Accounts.scope_for(Accounts.get_account!(scope.account.id))
      assert Accounts.workspace_locale(scope) == nil
    end
  end

  describe "SCIM role mapping" do
    test "sets roles, never the owner", %{scope: scope, workspace: workspace} do
      member = account_fixture()
      {:ok, _membership} = Accounts.scim_provision(workspace, member.email)

      {:ok, updated} = Accounts.scim_set_member_role(workspace, member.id, :editor)
      assert updated.role == :editor

      # Idempotent on the same role.
      {:ok, same} = Accounts.scim_set_member_role(workspace, member.id, :editor)
      assert same.role == :editor

      assert {:error, :owner} =
               Accounts.scim_set_member_role(workspace, scope.account.id, :normal)

      assert {:error, :not_found} =
               Accounts.scim_set_member_role(workspace, Ecto.UUID.generate(), :editor)
    end
  end

  describe "web push" do
    defp fake_subscription do
      {client_public, _client_private} = :crypto.generate_key(:ecdh, :prime256v1)

      %{
        "endpoint" => "https://push.example.com/send/abc123",
        "keys" => %{
          "p256dh" => Base.url_encode64(client_public, padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      }
    end

    test "subscribe / unsubscribe round-trip", %{account: account} do
      refute Flux.WebPush.subscribed?(account)

      {:ok, subscription} = Flux.WebPush.subscribe(account, fake_subscription())
      assert Flux.WebPush.subscribed?(account)

      # Re-subscribing the same endpoint upserts, not duplicates.
      {:ok, _again} =
        Flux.WebPush.subscribe(
          account,
          fake_subscription() |> Map.put("endpoint", subscription.endpoint)
        )

      assert [_one] = Flux.WebPush.subscriptions_for([account.id])

      assert {:error, :invalid_subscription} = Flux.WebPush.subscribe(account, %{"nope" => true})

      :ok = Flux.WebPush.unsubscribe(account, subscription.endpoint)
      refute Flux.WebPush.subscribed?(account)
    end

    test "delivery worker posts an encrypted payload with VAPID auth", %{account: account} do
      {:ok, subscription} = Flux.WebPush.subscribe(account, fake_subscription())

      Application.put_env(:flux, :webpush_req_options, plug: {Req.Test, Flux.WebPushStub})
      on_exit(fn -> Application.delete_env(:flux, :webpush_req_options) end)

      test_pid = self()

      Req.Test.stub(Flux.WebPushStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:pushed, Map.new(conn.req_headers), body})
        Plug.Conn.send_resp(conn, 201, "")
      end)

      assert :ok =
               Flux.WebPush.Worker.perform(%Oban.Job{
                 args: %{
                   "subscription_id" => subscription.id,
                   "title" => "A handoff is waiting",
                   "path" => "/console/apps"
                 }
               })

      assert_receive {:pushed, headers, body}
      # Req's test-plug adapter consumes the content-encoding request
      # header (it tries to decompress, then deletes it), so only the
      # rest of the wire format is assertable here.
      assert headers["authorization"] =~ "vapid t="
      assert headers["ttl"] == "86400"
      # RFC 8188 header: 16-byte salt + record size + key id length (65).
      assert <<_salt::binary-16, 4096::unsigned-32, 65, _rest::binary>> = body
    end

    test "a gone endpoint drops the subscription", %{account: account} do
      {:ok, subscription} = Flux.WebPush.subscribe(account, fake_subscription())

      Application.put_env(:flux, :webpush_req_options, plug: {Req.Test, Flux.WebPushStub})
      on_exit(fn -> Application.delete_env(:flux, :webpush_req_options) end)

      Req.Test.stub(Flux.WebPushStub, fn conn -> Plug.Conn.send_resp(conn, 410, "") end)

      assert :ok =
               Flux.WebPush.Worker.perform(%Oban.Job{
                 args: %{"subscription_id" => subscription.id, "title" => "gone?"}
               })

      refute Flux.WebPush.subscribed?(account)
    end

    test "urgent notification kinds enqueue push jobs", %{account: account, workspace: workspace} do
      {:ok, _subscription} = Flux.WebPush.subscribe(account, fake_subscription())

      :ok = Flux.Notifications.notify(workspace.id, "handoff", "visitor waiting", "/console")

      jobs =
        Flux.Repo.all(from(j in Oban.Job, where: j.worker == "Flux.WebPush.Worker"))

      assert [job] = jobs
      assert job.args["title"] == "visitor waiting"

      # Non-urgent kinds stay email/feed-only.
      :ok = Flux.Notifications.notify(workspace.id, "digest", "weekly digest", nil)

      assert Flux.Repo.all(from(j in Oban.Job, where: j.worker == "Flux.WebPush.Worker"))
             |> length() == 1
    end
  end
end
