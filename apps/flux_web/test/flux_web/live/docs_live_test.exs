defmodule FluxWeb.DocsLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Docs WS"})
    %{conn: log_in_account(conn, account)}
  end

  test "guides render in-app and switch via patch", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/console/docs")
    assert html =~ "Getting started"
    assert html =~ "mix flux.demo"

    html = lv |> element("a", "Node reference") |> render_click()
    assert html =~ "knowledge_retrieval"
    assert html =~ "max_iterations"

    # Headings get slugified ids so canvas docs links can anchor to them.
    assert html =~ ~s(<h3 id="llm">)
    assert html =~ ~s(<h3 id="knowledge_retrieval">)

    # Unknown slugs fall back to getting started.
    {:ok, _lv, html} = live(conn, ~p"/console/docs/nope")
    assert html =~ "mix flux.demo"
  end
end
