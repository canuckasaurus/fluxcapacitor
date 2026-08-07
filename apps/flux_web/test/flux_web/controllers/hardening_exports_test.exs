defmodule FluxWeb.HardeningExportsTest do
  @moduledoc "Conversation downloads and the audit CSV (batch-16 hardening)."
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Export WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Echo App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{conn: log_in_account(conn, account), scope: scope, app: app}
  end

  describe "conversation export" do
    setup %{scope: scope, app: app} do
      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hello export")
      assert_receive {:done, _final}, 5_000
      %{conversation: conversation}
    end

    test "markdown by default", %{conn: conn, app: app, conversation: conversation} do
      conn = get(conn, ~p"/console/apps/#{app.id}/conversations/#{conversation.id}/export")

      assert response_content_type(conn, :markdown) =~ "text/markdown"
      assert conn.resp_body =~ "**You**"
      assert conn.resp_body =~ "hello export"
      assert conn.resp_body =~ "**Assistant**"
    end

    test "json on request", %{conn: conn, app: app, conversation: conversation} do
      conn =
        get(
          conn,
          ~p"/console/apps/#{app.id}/conversations/#{conversation.id}/export?format=json"
        )

      decoded = Jason.decode!(conn.resp_body)
      assert decoded["id"] == conversation.id
      assert Enum.map(decoded["messages"], & &1["role"]) == ["user", "assistant"]
      assert hd(decoded["messages"])["content"] == "hello export"
    end

    test "another app's id is refused", %{conn: conn, scope: scope, conversation: conversation} do
      {:ok, other} =
        Chat.create_app(scope, %{
          "name" => "Other",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conn = get(conn, ~p"/console/apps/#{other.id}/conversations/#{conversation.id}/export")
      assert redirected_to(conn) == "/console/apps/#{other.id}"
    end
  end

  describe "audit CSV" do
    test "downloads the trail and honors the date window", %{conn: conn, scope: scope} do
      Flux.Audit.record(scope, "test.event", metadata: %{"note" => "hello, audit"})

      conn2 = get(conn, ~p"/console/audit-export")
      assert response_content_type(conn2, :csv) =~ "text/csv"
      assert conn2.resp_body =~ "when,actor,action"
      assert conn2.resp_body =~ "test.event"
      # Comma inside metadata stays quoted.
      assert conn2.resp_body =~ ~s("{""note"":""hello, audit""}")

      # A window entirely in the past excludes today's entry.
      conn3 = get(conn, ~p"/console/audit-export?from=2000-01-01&to=2000-12-31")
      refute conn3.resp_body =~ "test.event"
    end
  end
end
