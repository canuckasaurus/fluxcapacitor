defmodule FluxWeb.Batch41WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch41 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B41 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  # Waits for the conversation's newest assistant reply to finish so the
  # test never tears the sandbox down under a streaming generation.
  defp await_last_reply(scope, conversation_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      last =
        scope
        |> Chat.list_messages(conversation_id)
        |> List.last()

      case last do
        %{role: :assistant, status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end

  describe "monitor notes and resolve" do
    test "add a note, resolve, filter, reopen", %{conn: conn, account: account, scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{title: "Sticky issue"})

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}/monitor")

      lv
      |> element("button[phx-click='select'][phx-value-conversation-id='#{conversation.id}']")
      |> render_click()

      html =
        lv
        |> form("#note-form-#{conversation.id}", %{
          "conversation-id" => conversation.id,
          "body" => "VIP customer, be quick"
        })
        |> render_submit()

      assert html =~ "VIP customer, be quick"
      assert html =~ "never shown to the visitor"

      html =
        lv
        |> element("#resolve-#{conversation.id}")
        |> render_click()

      assert html =~ "reopen-#{conversation.id}"
      assert html =~ "1 resolved (30d)"

      # The open filter hides it; reopening brings it back.
      html = lv |> form("#status-filter", %{"filter" => "open"}) |> render_change()
      refute html =~ "Sticky issue"

      html = lv |> form("#status-filter", %{"filter" => "resolved"}) |> render_change()
      assert html =~ "Sticky issue"

      lv |> element("#reopen-#{conversation.id}") |> render_click()
      html = lv |> form("#status-filter", %{"filter" => "open"}) |> render_change()
      assert html =~ "Sticky issue"
    end
  end

  describe "live monitor feed" do
    test "new conversations appear without a reload, marked new", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
      refute html =~ "Fresh visitor"

      Chat.create_conversation(scope, app, %{title: "Fresh visitor"})

      html = render(lv)
      assert html =~ "Fresh visitor"
      assert html =~ "Changed since you last looked"
    end
  end

  describe "typing indicators" do
    test "the monitor sees the visitor typing on a handoff", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_typer"})
      {:ok, _flagged} = Chat.request_handoff(Chat.site_scope(app), app, conversation.id)

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
      refute html =~ "visitor is typing"

      Chat.broadcast_typing(conversation.id, :visitor)
      assert render(lv) =~ "visitor is typing"
    end

    test "the site sees the agent typing", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, lv, _html} = live(conn, ~p"/site/#{app.site_token}")

      lv
      |> form("#site-chat-form", %{"content" => "hello there"})
      |> render_submit()

      [conversation] = Chat.list_conversations(scope, app.id, 5)

      Chat.broadcast_typing(conversation.id, :agent)
      assert render(lv) =~ "typing"

      await_last_reply(scope, conversation.id)
    end
  end

  describe "business hours" do
    test "outside hours the site shows the away note and hides the handoff button", %{
      conn: conn,
      scope: scope
    } do
      # A zero-width window on every day is deterministically closed.
      closed_hours = %{
        "days" => ~w(mon tue wed thu fri sat sun),
        "open" => 0,
        "close" => 0,
        "note" => "Back at 9am UTC — leave a message!"
      }

      app = echo_app(scope, %{"business_hours" => closed_hours})
      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, lv, html} = live(conn, ~p"/site/#{app.site_token}")
      assert html =~ "Back at 9am UTC"

      lv |> form("#site-chat-form", %{"content" => "anyone there?"}) |> render_submit()
      refute render(lv) =~ "request-handoff"

      [conversation] = Chat.list_conversations(scope, app.id, 5)
      await_last_reply(scope, conversation.id)
    end

    test "the app page saves and clears the weekly schedule", %{
      conn: conn,
      account: account,
      scope: scope
    } do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

      lv
      |> form("#business-hours-form", %{
        "days" => ["mon", "tue"],
        "open" => "9",
        "close" => "17",
        "note" => "Weekdays only"
      })
      |> render_submit()

      saved = Chat.get_app(scope, app.id)
      assert saved.business_hours["days"] == ["mon", "tue"]
      assert saved.business_hours["open"] == 9
      assert saved.business_hours["note"] == "Weekdays only"

      # No days checked clears the schedule.
      lv
      |> form("#business-hours-form", %{
        "days" => [],
        "open" => "9",
        "close" => "17",
        "note" => ""
      })
      |> render_submit()

      assert Chat.get_app(scope, app.id).business_hours == %{}
    end
  end

  describe "workspace settings" do
    test "handoff SLA alert and mail branding save", %{
      conn: conn,
      account: account,
      workspace: workspace
    } do
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/settings")
      assert html =~ "handoff-alert-form"
      assert html =~ "mail-branding-form"

      lv |> form("#handoff-alert-form", %{"minutes" => "15"}) |> render_submit()

      lv
      |> form("#mail-branding-form", %{
        "from_name" => "Acme Support",
        "reply_to" => "support@acme.com"
      })
      |> render_submit()

      workspace = Flux.Repo.get!(Flux.Accounts.Workspace, workspace.id)
      assert workspace.custom_config["handoff_alert_minutes"] == 15

      assert workspace.custom_config["mail_branding"] == %{
               "from_name" => "Acme Support",
               "reply_to" => "support@acme.com"
             }
    end
  end
end
