defmodule FluxWeb.KnowledgeLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.RAG

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Knowledge WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope}
  end

  test "an empty workspace gets the themed empty state", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/console/knowledge")
    assert html =~ "No knowledge yet"
    assert html =~ "outatime-plate"
  end

  test "create dataset, paste a document, index, and hit-test", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/console/knowledge")

    lv |> element("button", "New dataset") |> render_click()

    lv
    |> form("#dataset-form", %{
      "name" => "Handbook",
      "description" => "",
      "embedding_choice" => "echo|echo-embed"
    })
    |> render_submit()

    [dataset] = RAG.list_datasets(scope)
    assert dataset.name == "Handbook"
    assert dataset.embedding_model == "echo-embed"

    # Paste text → queued; drain Oban → indexed.
    lv
    |> form("#paste-form", %{
      "name" => "vacation.md",
      "content" => "Vacation policy: employees receive 25 paid days per year."
    })
    |> render_submit()

    Oban.drain_queue(queue: :ingest)
    html = lv |> element("button[phx-click=refresh]") |> render_click()
    assert html =~ "ready"
    assert html =~ "vacation.md"

    # Hit testing surfaces the segment.
    html =
      lv
      |> form("#hit-test-form", %{"query" => "how many vacation days?"})
      |> render_submit()

    assert html =~ "25 paid days"
  end
end
