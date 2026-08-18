defmodule Flux.Batch42Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch42 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B42 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  describe "CSAT" do
    test "rate, re-rate, comment, and roll up", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      {:ok, rated} = Chat.rate_conversation(scope, conversation.id, 4)
      assert rated.csat_score == 4

      {:ok, rerated} = Chat.rate_conversation(scope, conversation.id, 5, "great help!")
      assert rerated.csat_score == 5
      assert rerated.csat_comment == "great help!"

      other = Chat.create_conversation(scope, app)
      {:ok, _low} = Chat.rate_conversation(scope, other.id, 2)

      stats = Chat.csat_stats(scope, app.id)
      assert stats.count == 2
      assert stats.average == 3.5

      assert Chat.csat_stats(scope, Ecto.UUID.generate()).count == 0
    end
  end

  describe "conversation share links" do
    test "mint once, resolve publicly, revoke", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{title: "Shared thread"})

      {:ok, shared} = Chat.enable_conversation_share(scope, conversation.id)
      assert String.starts_with?(shared.share_token, "convshare_")

      # Idempotent: sharing again keeps the same token.
      {:ok, again} = Chat.enable_conversation_share(scope, conversation.id)
      assert again.share_token == shared.share_token

      assert {:ok, found, found_app, _messages} =
               Chat.get_shared_conversation(shared.share_token)

      assert found.id == conversation.id
      assert found_app.id == app.id

      {:ok, _revoked} = Chat.disable_conversation_share(scope, conversation.id)
      assert {:error, :not_found} = Chat.get_shared_conversation(shared.share_token)
      assert {:error, :not_found} = Chat.get_shared_conversation("convshare_nope")
    end
  end

  describe "handoff auto-assignment" do
    test "round-robins across available members when enabled", %{scope: scope} do
      app = echo_app(scope)
      {:ok, _workspace} = Accounts.set_handoff_auto_assign(scope, true)

      # Off the roster: an unavailable member never gets a handoff.
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_rr1"})
      {:ok, assigned} = Chat.request_handoff(scope, app, conversation.id)
      assert assigned.assigned_account_id == scope.account.id

      {:ok, _membership} = Accounts.set_availability(scope, false)
      assert Accounts.available_member_ids(Flux.Accounts.Scope.workspace_id(scope)) == []

      second = Chat.create_conversation(scope, app, %{end_user_ref: "web_rr2"})
      {:ok, unassigned} = Chat.request_handoff(scope, app, second.id)
      assert unassigned.assigned_account_id == nil

      # Turned off entirely: nobody is auto-assigned.
      {:ok, _membership} = Accounts.set_availability(scope, true)
      {:ok, _workspace} = Accounts.set_handoff_auto_assign(scope, false)

      third = Chat.create_conversation(scope, app, %{end_user_ref: "web_rr3"})
      {:ok, manual} = Chat.request_handoff(scope, app, third.id)
      assert manual.assigned_account_id == nil
    end
  end

  describe "human reply attachments and read receipts" do
    test "files ride the reply; the visitor's tab marks it seen", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_seen"})

      files = [%{"name" => "invoice.pdf", "download_token" => "file_test_b42"}]

      {:ok, message} =
        Chat.human_reply(scope, conversation.id, "here's the invoice", files: files)

      assert [%{"name" => "invoice.pdf"}] = message.files
      assert message.seen_at == nil

      site_scope = Chat.site_scope(app)
      :ok = Chat.mark_replies_seen(site_scope, conversation.id)

      seen = Flux.Repo.get!(Flux.Chat.Message, message.id, skip_workspace_guard: true)
      assert seen.seen_at != nil
    end

    test "downloadable uploads mint a file_ token", %{scope: scope} do
      app = echo_app(scope)

      path = Path.join(System.tmp_dir!(), "b42-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "attachment body")
      on_exit(fn -> File.rm(path) end)

      {:ok, plain} = Chat.create_upload(scope, app, %{path: path, filename: "plain.txt"})
      assert plain.download_token == nil

      {:ok, downloadable} =
        Chat.create_upload(scope, app, %{path: path, filename: "sent.txt", downloadable: true})

      assert String.starts_with?(downloadable.download_token, "file_")
    end
  end

  describe "Slack channel" do
    test "token lifecycle and inbound turn with posted reply", %{scope: scope} do
      app = echo_app(scope)

      {:ok, app} = Chat.enable_slack_channel(scope, app, "xoxb-test-token")
      assert String.starts_with?(app.slack_channel_token, "slch_")
      assert {:ok, _found} = Chat.get_app_by_slack_channel_token(app.slack_channel_token)

      test_pid = self()

      Application.put_env(:flux, :slack_client, fn bot_token, payload ->
        send(test_pid, {:slack_post, bot_token, payload})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:flux, :slack_client) end)

      {:ok, conversation_id} =
        Chat.slack_inbound(app, "C123", "U456", "where is the flux capacitor?", "111.222")

      site_scope = Chat.site_scope(app)
      conversation = Chat.get_conversation(site_scope, conversation_id)
      assert conversation.end_user_ref == "slack:C123:U456"

      assert_receive {:slack_post, "xoxb-test-token", payload}, 5_000
      assert payload["channel"] == "C123"
      assert payload["thread_ts"] == "111.222"
      assert payload["text"] != ""

      # Same channel + user threads into the same conversation.
      {:ok, same_id} = Chat.slack_inbound(app, "C123", "U456", "follow-up")
      assert same_id == conversation_id
      assert_receive {:slack_post, _token, _payload}, 5_000

      {:ok, disabled} = Chat.disable_slack_channel(scope, app)
      assert disabled.slack_channel_token == nil
      assert disabled.slack_bot_token == nil
    end
  end

  describe "webhook auto-disable" do
    test "fifteen straight failures disable the endpoint; a success resets", %{scope: scope} do
      {:ok, endpoint} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://hooks.example.com/dying",
          "events" => ["run.failed"]
        })

      delivery =
        Flux.Repo.insert!(%Flux.Webhooks.Delivery{
          workspace_id: endpoint.workspace_id,
          endpoint_id: endpoint.id,
          event: "run.failed",
          url: endpoint.url,
          payload: %{}
        })

      reload = fn ->
        Flux.Repo.get!(Flux.Webhooks.Endpoint, endpoint.id, skip_workspace_guard: true)
      end

      # Failures accumulate but one success clears the slate.
      for _try <- 1..10, do: Flux.Webhooks.record_attempt(delivery.id, 1, 500, "boom")
      assert reload.().consecutive_failures == 10
      :ok = Flux.Webhooks.record_attempt(delivery.id, 1, 200, nil)
      assert reload.().consecutive_failures == 0
      assert reload.().enabled

      for _try <- 1..15, do: Flux.Webhooks.record_attempt(delivery.id, 1, 503, "down")

      disabled = reload.()
      refute disabled.enabled

      assert Enum.any?(
               Flux.Notifications.list(scope),
               &(&1.kind == "webhook_disabled" and &1.title =~ "dying")
             )
    end
  end
end
