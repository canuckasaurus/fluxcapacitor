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

  test "the API reference renders from the live OpenAPI spec", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/console/docs/api-reference")

    # Endpoints table from the spec paths.
    assert html =~ "Service API reference"
    assert html =~ "/v1/chat-messages"
    assert html =~ "/v1/workflows/run"
    assert html =~ "Send a chat message"

    # Schemas section with anchors and field tables.
    assert html =~ ~s(id="schema-ChatMessage")
    assert html =~ ~s(id="schema-Error")
    assert html =~ "conversation_id"
    assert html =~ "required"
  end

  test "the palette endpoint lists pages and workspace entities", %{conn: conn} do
    conn = get(conn, ~p"/console/palette")
    %{"entries" => entries} = json_response(conn, 200)

    labels = Enum.map(entries, & &1["label"])
    assert "Dashboard" in labels
    assert "Runs" in labels
    assert Enum.all?(entries, &(is_binary(&1["url"]) and is_binary(&1["kind"])))
  end

  test "guide images rewrite to console paths and the assets exist", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/console/docs/getting-started")

    # The markdown says ../images/ (GitHub-relative); in-app it must
    # serve from /images/, and the static file must actually ship.
    assert html =~ ~s(src="/images/flux-assistant.jpg")
    refute html =~ "../images/"
    assert File.exists?(Path.join(:code.priv_dir(:flux_web), "static/images/flux-assistant.jpg"))
  end
end
