defmodule Flux.Batch41Test do
  use Flux.DataCase, async: false
  use Oban.Testing, repo: Flux.Repo

  import Flux.AccountsFixtures
  import Swoosh.TestAssertions

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch41 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B41 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp await_completion(message_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      case Flux.Repo.get!(Flux.Chat.Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end

  describe "internal notes" do
    test "add, list, delete; blank refused", %{scope: scope, account: account} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      assert Chat.list_conversation_notes(scope, conversation.id) == []
      assert {:error, :blank} = Chat.add_conversation_note(scope, conversation.id, "   ")

      {:ok, note} = Chat.add_conversation_note(scope, conversation.id, "VIP — expedite")
      assert note.author_email == account.email

      assert [%{body: "VIP — expedite"}] = Chat.list_conversation_notes(scope, conversation.id)

      {:ok, _deleted} = Chat.delete_conversation_note(scope, note.id)
      assert Chat.list_conversation_notes(scope, conversation.id) == []
    end
  end

  describe "resolve states" do
    test "resolve, counts, and reopen on a fresh visitor message", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      {:ok, resolved} = Chat.resolve_conversation(scope, conversation.id)
      assert resolved.resolved_at != nil

      counts = Chat.resolution_counts(scope, app.id)
      assert counts.resolved == 1

      # A new message reopens the thread without anyone clicking.
      {:ok, _user, assistant} = Chat.send_message(scope, app, resolved, "hello again")
      await_completion(assistant.id)

      reopened = Chat.get_conversation(scope, conversation.id)
      assert reopened.resolved_at == nil
      assert Chat.resolution_counts(scope, app.id).open == 1

      {:ok, resolved_again} = Chat.resolve_conversation(scope, conversation.id)
      {:ok, back_open} = Chat.reopen_conversation(scope, resolved_again.id)
      assert back_open.resolved_at == nil
    end
  end

  describe "business hours" do
    test "windows, overnight wrap, and always-open default", %{scope: scope} do
      app = echo_app(scope)
      # A Wednesday at 10:00 UTC.
      wed_10 = DateTime.new!(~D[2026-08-19], ~T[10:00:00])
      wed_23 = DateTime.new!(~D[2026-08-19], ~T[23:00:00])
      sun_10 = DateTime.new!(~D[2026-08-23], ~T[10:00:00])

      assert Chat.within_business_hours?(app, wed_10)

      weekday = %{
        app
        | business_hours: %{"days" => ~w(mon tue wed thu fri), "open" => 9, "close" => 17}
      }

      assert Chat.within_business_hours?(weekday, wed_10)
      refute Chat.within_business_hours?(weekday, wed_23)
      refute Chat.within_business_hours?(weekday, sun_10)

      # Overnight window: 22:00 to 06:00 wraps past midnight.
      night = %{app | business_hours: %{"days" => ~w(wed), "open" => 22, "close" => 6}}
      assert Chat.within_business_hours?(night, wed_23)
      refute Chat.within_business_hours?(night, wed_10)
    end
  end

  describe "handoff SLA alerts" do
    test "fires once when overdue, re-arms on a fresh request", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _workspace} = Accounts.set_handoff_alert_minutes(scope, 10)

      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_sla"})
      {:ok, _flagged} = Chat.request_handoff(scope, app, conversation.id)

      overdue_alerts = fn ->
        Enum.count(
          Flux.Notifications.list(scope),
          &(&1.kind == "handoff" and &1.title =~ "waiting 10+")
        )
      end

      # Not overdue yet: silent.
      :ok = Chat.check_handoff_sla()
      assert overdue_alerts.() == 0

      # Backdate the request past the threshold: one alert, no repeats.
      backdated = DateTime.add(DateTime.utc_now(:second), -15, :minute)

      Flux.Repo.update_all(
        from(c in Flux.Chat.Conversation,
          where: c.id == ^conversation.id and c.workspace_id == ^workspace.id
        ),
        set: [handoff_requested_at: backdated]
      )

      :ok = Chat.check_handoff_sla()
      :ok = Chat.check_handoff_sla()
      assert overdue_alerts.() == 1

      # A human answers, the visitor asks again: the alert is re-armed.
      {:ok, _message} = Chat.human_reply(scope, conversation.id, "here now")
      {:ok, _again} = Chat.request_handoff(scope, app, conversation.id)

      Flux.Repo.update_all(
        from(c in Flux.Chat.Conversation,
          where: c.id == ^conversation.id and c.workspace_id == ^workspace.id
        ),
        set: [handoff_requested_at: backdated]
      )

      :ok = Chat.check_handoff_sla()
      assert overdue_alerts.() == 2
    end
  end

  describe "conversation webhook events" do
    test "started, message.completed, and handoff.requested dispatch", %{scope: scope} do
      {:ok, _endpoint} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://hooks.example.com/chat-events",
          "events" => ["conversation.started", "message.completed", "handoff.requested"]
        })

      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_hooked"})
      {:ok, _flagged} = Chat.request_handoff(scope, app, conversation.id)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "ping")

      # Wait for the echo generation to finalize.
      await_completion(assistant.id)

      events =
        all_enqueued(worker: Flux.Workflows.AlertWorker)
        |> Enum.filter(&(&1.args["url"] == "https://hooks.example.com/chat-events"))
        |> Enum.map(& &1.args["payload"]["event"])

      assert "conversation.started" in events
      assert "handoff.requested" in events
      assert "message.completed" in events
    end
  end

  describe "mail branding" do
    test "workspace mail carries the from-name and reply-to", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _workspace} = Accounts.set_mail_branding(scope, "Acme Support", "support@acme.com")

      drain_emails()

      Flux.Accounts.AccountNotifier.deliver_notification_email(
        "member@example.com",
        "handoff",
        "A visitor asked for a human.",
        nil,
        workspace.id
      )

      assert_email_sent(fn email ->
        {from_name, _address} = email.from

        from_name == "Acme Support" and
          email.subject =~ "[Acme Support]" and
          Enum.any?(email.reply_to && List.wrap(email.reply_to), fn
            {_name, "support@acme.com"} -> true
            _other -> false
          end)
      end)

      # Unbranded workspaces keep the platform default.
      Flux.Accounts.AccountNotifier.deliver_notification_email(
        "member@example.com",
        "handoff",
        "Another one.",
        nil,
        nil
      )

      assert_email_sent(fn email ->
        {from_name, _address} = email.from
        from_name == "FluxCapacitor"
      end)

      assert {:error, :invalid_reply_to} =
               Accounts.set_mail_branding(scope, "Acme", "not an email")

      {:ok, _cleared} = Accounts.set_mail_branding(scope, "", "")
    end
  end

  describe "monitor feed and typing" do
    test "conversation changes nudge the monitor topic; typing rides the conversation topic",
         %{scope: scope} do
      app = echo_app(scope)
      :ok = Chat.subscribe_monitor(app.id)

      conversation = Chat.create_conversation(scope, app)
      conversation_id = conversation.id
      assert_receive {:monitor_update, ^conversation_id}

      :ok = Chat.subscribe_conversation(conversation.id)
      :ok = Chat.broadcast_typing(conversation.id, :visitor)
      assert_receive {:typing, ^conversation_id, :visitor}
    end
  end
end
