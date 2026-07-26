defmodule FluxWeb.AppChatLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Chat UI WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "UI Echo",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{conn: log_in_account(conn, account), app: app, scope: scope}
  end

  test "apps index lists apps and links to chat", %{conn: conn, app: app} do
    {:ok, _lv, html} = live(conn, ~p"/console/apps")
    assert html =~ app.name
    assert html =~ "Open chat"
  end

  test "sending a message streams and completes", %{conn: conn, app: app} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    lv
    |> form("#chat-form", %{"content" => "hello ui"})
    |> render_submit()

    # Poll until the streamed reply lands in the completed message list.
    html = poll_until(lv, "You said: hello ui", 50)
    assert html =~ "You said: hello ui"
  end

  test "creating an API key shows the raw token once", %{conn: conn, app: app} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    html = lv |> element("button", "Create key") |> render_click()
    assert html =~ "app-"
    assert html =~ "Copy this key now"
  end

  defp poll_until(lv, needle, retries) do
    html = render(lv)

    cond do
      html =~ needle ->
        html

      retries == 0 ->
        html

      true ->
        Process.sleep(50)
        poll_until(lv, needle, retries - 1)
    end
  end
end
