defmodule Flux.Batch36Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch36 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B36 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp wait_for_completion(message_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      case Flux.Repo.get!(Flux.Chat.Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end

  describe "app snapshots" do
    test "save, restore, delete", %{scope: scope} do
      app = echo_app(scope, %{"system_prompt" => "be brief"})

      {:ok, snapshot} = Chat.snapshot_app(scope, app, "before rewrite")
      assert snapshot.config["system_prompt"] == "be brief"

      {:ok, app} = Chat.update_app(scope, app, %{"system_prompt" => "be verbose"})
      assert app.system_prompt == "be verbose"

      {:ok, restored} = Chat.restore_app_snapshot(scope, app, snapshot.id)
      assert restored.system_prompt == "be brief"

      assert [_one] = Chat.list_app_snapshots(scope, app.id)
      {:ok, _deleted} = Chat.delete_app_snapshot(scope, snapshot.id)
      assert Chat.list_app_snapshots(scope, app.id) == []

      assert {:error, :empty} = Chat.snapshot_app(scope, app, "  ")
    end
  end

  describe "fallback chains" do
    test "the ordered list is tried after the legacy fallback", %{scope: scope} do
      app =
        echo_app(scope, %{
          "provider_plugin_id" => "nope",
          "model" => "ghost",
          "fallbacks" => [
            %{"provider_plugin_id" => "also-nope", "model" => "ghost-2"},
            %{"provider_plugin_id" => "echo", "model" => "echo-1"}
          ]
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "who answers?")
      done = wait_for_completion(assistant.id)

      assert done.status == :completed
      assert done.usage["fallback_used"] == true
      assert done.usage["model_used"] == "echo/echo-1"
    end
  end

  describe "prompt A/B" do
    test "prompt_split 100 answers on arm B and records it", %{scope: scope} do
      app = echo_app(scope, %{"prompt_b" => "alternative persona", "prompt_split" => 100})

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "which arm?")
      done = wait_for_completion(assistant.id)

      assert done.usage["prompt_variant"] == "b"

      stats = Chat.prompt_ab_stats(scope, app.id)
      assert stats["b"].replies == 1
      assert stats["a"].replies == 0
    end
  end

  describe "quiet hours" do
    test "window math, including midnight wrap", %{account: account} do
      {:ok, account} = Accounts.set_quiet_hours(account, 22, 7)
      assert Accounts.in_quiet_hours?(account, 23)
      assert Accounts.in_quiet_hours?(account, 3)
      refute Accounts.in_quiet_hours?(account, 12)

      {:ok, account} = Accounts.set_quiet_hours(account, 9, 17)
      assert Accounts.in_quiet_hours?(account, 12)
      refute Accounts.in_quiet_hours?(account, 20)

      {:ok, account} = Accounts.set_quiet_hours(account, nil, nil)
      refute Accounts.in_quiet_hours?(account, 3)
    end

    test "notify defers the email as a scheduled Oban job", %{
      account: account,
      workspace: workspace
    } do
      now_hour = DateTime.utc_now().hour
      {:ok, _account} = Accounts.set_notification_email_kinds(account, ["run_failed"])
      {:ok, _account} = Accounts.set_quiet_hours(account, now_hour, rem(now_hour + 2, 24))

      :ok = Flux.Notifications.notify(workspace.id, "run_failed", "deferred?", "/console")

      deferred =
        Flux.Repo.all(
          from(j in Oban.Job,
            where: j.worker == "Flux.Notifications.EmailWorker" and j.state == "scheduled"
          )
        )

      assert [job] = deferred
      assert job.args["email"] == account.email
      assert job.args["title"] == "deferred?"
    end
  end

  describe "handoff SLA" do
    test "the first human reply records the wait", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_sla"})
      {:ok, _flagged} = Chat.request_handoff(scope, app, conversation.id)

      {:ok, _message} = Chat.human_reply(scope, conversation.id, "a human is here")

      reloaded =
        Flux.Repo.get!(Flux.Chat.Conversation, conversation.id, skip_workspace_guard: true)

      assert is_integer(reloaded.handoff_first_reply_seconds)
      assert reloaded.handoff_requested_at == nil

      assert %{count: 1, median_seconds: median} = Chat.handoff_sla(scope, app.id)
      assert median >= 0
    end
  end

  describe "webhook secret rotation" do
    test "regenerates the whsec_", %{scope: scope} do
      {:ok, endpoint} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://example.com/hook",
          "events" => ["run.succeeded"]
        })

      old_secret = endpoint.secret
      {:ok, rotated} = Flux.Webhooks.rotate_secret(scope, endpoint.id)

      assert rotated.secret != old_secret
      assert String.starts_with?(rotated.secret, "whsec_")
    end
  end

  describe "digest frequency" do
    test "daily digests fire off-Monday; off silences them", %{scope: scope, workspace: workspace} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Digest Flux"})

      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :succeeded
      })

      # A Tuesday 08:00 — weekly stays silent, daily speaks.
      tuesday = DateTime.new!(~D[2026-08-11], ~T[08:00:00], "Etc/UTC")

      assert :ok = Flux.Usage.send_weekly_digests(tuesday)
      assert digest_count(scope) == 0

      {:ok, _workspace} = Accounts.set_digest_frequency(scope, "daily")
      assert :ok = Flux.Usage.send_weekly_digests(tuesday)
      assert digest_count(scope) == 1

      {:ok, _workspace} = Accounts.set_digest_frequency(scope, "off")
      wednesday = DateTime.new!(~D[2026-08-12], ~T[08:00:00], "Etc/UTC")
      assert :ok = Flux.Usage.send_weekly_digests(wednesday)
      assert digest_count(scope) == 1
    end
  end

  describe "conversation usage" do
    test "sums assistant tokens", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "count me")
      wait_for_completion(assistant.id)

      usage = Chat.conversation_usage(scope, conversation.id)
      assert usage.input_tokens + usage.output_tokens > 0
    end
  end

  describe "favorites" do
    test "toggle and list", %{account: account, scope: scope} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Starred Flux"})

      {:ok, :starred} = Accounts.toggle_favorite(account, "flux", workflow.id)
      assert MapSet.member?(Accounts.favorite_ids(account, "flux"), workflow.id)

      {:ok, :unstarred} = Accounts.toggle_favorite(account, "flux", workflow.id)
      refute MapSet.member?(Accounts.favorite_ids(account, "flux"), workflow.id)
    end
  end

  defp digest_count(scope) do
    scope |> Flux.Notifications.list() |> Enum.count(&(&1.kind == "digest"))
  end
end
