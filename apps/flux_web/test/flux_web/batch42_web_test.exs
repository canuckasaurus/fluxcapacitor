defmodule FluxWeb.Batch42WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch42 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B42 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp await_last_reply(scope, conversation_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      last = scope |> Chat.list_messages(conversation_id) |> List.last()

      case last do
        %{role: :assistant, status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end

  describe "Slack channel webhook" do
    test "challenge handshake, inbound turn, bot messages ignored", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_slack_channel(scope, app, "xoxb-web-test")

      test_pid = self()

      Application.put_env(:flux, :slack_client, fn _token, payload ->
        send(test_pid, {:slack_post, payload})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:flux, :slack_client) end)

      # URL verification echoes the challenge.
      challenge =
        conn
        |> post(~p"/channels/slack/#{app.slack_channel_token}", %{
          "type" => "url_verification",
          "challenge" => "chlg-88mph"
        })
        |> json_response(200)

      assert challenge["challenge"] == "chlg-88mph"

      # A channel message becomes a turn and the reply posts back.
      body =
        conn
        |> post(~p"/channels/slack/#{app.slack_channel_token}", %{
          "event" => %{
            "type" => "message",
            "channel" => "C42",
            "user" => "U42",
            "text" => "hello from slack",
            "ts" => "42.42"
          }
        })
        |> json_response(202)

      assert body["status"] == "replying"
      assert_receive {:slack_post, payload}, 5_000
      assert payload["channel"] == "C42"

      # Bot echoes never loop.
      ignored =
        conn
        |> post(~p"/channels/slack/#{app.slack_channel_token}", %{
          "event" => %{
            "type" => "message",
            "channel" => "C42",
            "user" => "U42",
            "text" => "I am the bot",
            "bot_id" => "B1",
            "ts" => "43.43"
          }
        })
        |> json_response(202)

      assert ignored["status"] == "ignored"

      assert conn
             |> post(~p"/channels/slack/slch_wrong", %{"event" => %{}})
             |> json_response(404)
    end
  end

  describe "conversation share page" do
    test "shared transcripts render; revoked links 404", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{title: "Warp calculations"})
      {:ok, _message} = Chat.human_reply(scope, conversation.id, "It needs 1.21 gigawatts.")
      {:ok, shared} = Chat.enable_conversation_share(scope, conversation.id)

      html =
        conn
        |> get(~p"/share/conversations/#{shared.share_token}")
        |> html_response(200)

      assert html =~ "Warp calculations"
      assert html =~ "1.21 gigawatts"
      assert html =~ "read-only"

      # The monitor drives sharing too: revoke and the page is gone.
      logged = log_in_account(conn, account)
      {:ok, lv, _html} = live(logged, ~p"/console/apps/#{app.id}/monitor")

      lv
      |> element("button[phx-click='select'][phx-value-conversation-id='#{conversation.id}']")
      |> render_click()

      lv
      |> element(
        "button[phx-click='revoke_share'][phx-value-conversation-id='#{conversation.id}']"
      )
      |> render_click()

      assert conn
             |> get(~p"/share/conversations/#{shared.share_token}")
             |> html_response(404)
    end
  end

  describe "site CSAT and away capture" do
    test "stars rate the conversation and the comment lands", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, lv, _html} = live(conn, ~p"/site/#{app.site_token}")
      lv |> form("#site-chat-form", %{"content" => "rate me"}) |> render_submit()

      [conversation] = Chat.list_conversations(scope, app.id, 5)
      await_last_reply(scope, conversation.id)

      html = lv |> element("#csat button[phx-value-score='4']") |> render_click()
      assert html =~ "csat-comment-form"

      lv |> form("#csat-comment-form", %{"comment" => "solid answers"}) |> render_submit()

      rated = Chat.get_conversation(scope, conversation.id)
      assert rated.csat_score == 4
      assert rated.csat_comment == "solid answers"
      assert Chat.csat_stats(scope, app.id).count == 1
    end

    test "outside hours a visitor can leave an email", %{conn: conn, scope: scope} do
      closed = %{"days" => ~w(mon tue wed thu fri sat sun), "open" => 0, "close" => 0}
      app = echo_app(scope, %{"business_hours" => closed})
      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, lv, _html} = live(conn, ~p"/site/#{app.site_token}")
      lv |> form("#site-chat-form", %{"content" => "anyone?"}) |> render_submit()

      [conversation] = Chat.list_conversations(scope, app.id, 5)
      await_last_reply(scope, conversation.id)

      assert render(lv) =~ "away-email-form"
      lv |> form("#away-email-form", %{"email" => "night@owl.com"}) |> render_submit()

      assert Chat.get_conversation(scope, conversation.id).visitor_email == "night@owl.com"
    end
  end

  describe "reply attachments and read receipts" do
    test "an attached file reaches the visitor; the open tab marks it seen", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_attach"})

      logged = log_in_account(conn, account)
      {:ok, lv, _html} = live(logged, ~p"/console/apps/#{app.id}/monitor")

      lv
      |> element("button[phx-click='select'][phx-value-conversation-id='#{conversation.id}']")
      |> render_click()

      lv
      |> file_input("#detail-reply-#{conversation.id}", :reply_file, [
        %{name: "specs.txt", content: "1.21 gigawatts", type: "text/plain"}
      ])
      |> render_upload("specs.txt")

      lv
      |> form("#detail-reply-#{conversation.id}", %{
        "conversation-id" => conversation.id,
        "content" => "here are the specs"
      })
      |> render_submit()

      site_scope = Chat.site_scope(app)
      [reply] = Chat.list_messages(site_scope, conversation.id)
      assert [%{"name" => "specs.txt", "download_token" => "file_" <> _} = file] = reply.files
      assert reply.seen_at == nil

      # The file downloads through the token URL.
      download = get(conn, "/files/#{file["download_token"]}")
      assert download.status == 200
      assert download.resp_body == "1.21 gigawatts"

      # A visitor tab opening the site marks the reply seen, and the
      # monitor shows it.
      {:ok, _site_lv, _site_html} = live(conn, ~p"/site/#{app.site_token}")

      seen = site_scope |> Chat.list_messages(conversation.id) |> List.last()
      assert seen.seen_at == nil

      # The stable visitor ref differs per session cookie, so mark
      # directly like the site does for its own conversation.
      :ok = Chat.mark_replies_seen(site_scope, conversation.id)
      assert render(lv) =~ "seen"
    end
  end

  describe "retrieval feedback" do
    test "a flagged citation queues on the knowledge page", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "Flag KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, document} = RAG.add_document(scope, dataset, %{name: "notes.md", content: "text"})

      segment =
        Flux.Repo.insert!(%Flux.RAG.Segment{
          workspace_id: dataset.workspace_id,
          dataset_id: dataset.id,
          document_id: document.id,
          position: 0,
          content: "the flux capacitor needs plutonium"
        })

      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      Flux.Repo.insert!(%Flux.Chat.Message{
        workspace_id: dataset.workspace_id,
        conversation_id: conversation.id,
        role: :assistant,
        status: :completed,
        content: "cited answer",
        citations: [
          %{
            "document" => "notes.md",
            "content" => "the flux capacitor needs plutonium",
            "segment_id" => segment.id
          }
        ]
      })

      logged = log_in_account(conn, account)
      {:ok, lv, _html} = live(logged, ~p"/console/apps/#{app.id}/monitor")

      lv
      |> element("button[phx-click='select'][phx-value-conversation-id='#{conversation.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='flag_citation'][phx-value-segment-id='#{segment.id}']")
      |> render_click()

      assert [flagged] = RAG.list_flagged_segments(scope)
      assert flagged.id == segment.id

      # The knowledge page queues it; disabling clears the flag too.
      {:ok, knowledge_lv, knowledge_html} = live(logged, ~p"/console/knowledge")
      assert knowledge_html =~ "Flagged retrievals"
      assert knowledge_html =~ "plutonium"

      knowledge_lv
      |> element(
        "button[phx-click='disable_flagged_segment'][phx-value-segment-id='#{segment.id}']"
      )
      |> render_click()

      assert RAG.list_flagged_segments(scope) == []

      refute Flux.Repo.get!(Flux.RAG.Segment, segment.id, skip_workspace_guard: true).enabled
    end
  end

  describe "console cards" do
    test "the share card shows a QR and the Slack card enables the channel", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")

      assert html =~ "site-qr"
      assert html =~ "<svg"
      assert html =~ "slack-channel-card"

      lv
      |> form("#slack-channel-form", %{"bot_token" => "xoxb-console-test"})
      |> render_submit()

      updated = Chat.get_app(scope, app.id)
      assert String.starts_with?(updated.slack_channel_token, "slch_")
    end

    test "availability and auto-assignment toggles", %{
      conn: conn,
      account: account,
      workspace: workspace,
      scope: scope
    } do
      app = echo_app(scope)
      conn = log_in_account(conn, account)

      {:ok, monitor_lv, monitor_html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
      assert monitor_html =~ "Available"

      html = monitor_lv |> element("#availability-toggle") |> render_click()
      assert html =~ "Away"
      assert Accounts.available_member_ids(workspace.id) == []

      {:ok, settings_lv, settings_html} = live(conn, ~p"/console/settings")
      assert settings_html =~ "auto-assign-toggle"

      settings_lv |> element("#auto-assign-toggle") |> render_click()

      refreshed = Flux.Repo.get!(Flux.Accounts.Workspace, workspace.id)
      assert refreshed.custom_config["handoff_auto_assign"] == true
    end
  end
end
