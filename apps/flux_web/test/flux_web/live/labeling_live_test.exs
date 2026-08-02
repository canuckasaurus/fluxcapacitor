defmodule FluxWeb.LabelingLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Labeling

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Tagging WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope}
  end

  test "create a project, import a CSV, tag the queue, relabel, export", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, html} = live(conn, ~p"/console/labeling")
    assert html =~ "Labeling"

    lv
    |> form("#create-project-form", %{
      "name" => "Intent",
      "label_type" => "choice",
      "options" => "complaint, question",
      "instructions" => "Pick the caller's intent."
    })
    |> render_submit()

    csv = "text\r\nrefund me now\r\nwhat are your hours\r\n"

    upload =
      file_input(lv, "#import-tasks-form", :tasks_csv, [
        %{name: "tasks.csv", content: csv, type: "text/csv"}
      ])

    render_upload(upload, "tasks.csv")
    html = lv |> form("#import-tasks-form") |> render_submit()

    assert html =~ "Imported 2 tasks."
    assert html =~ "refund me now"
    assert html =~ "Pick the caller&#39;s intent."

    [project] = Labeling.list_projects(scope)
    first = Labeling.next_task(scope, project.id)

    # Tag the first task via its choice button.
    html =
      lv
      |> element("#task-#{first.id} button", "complaint")
      |> render_click()

    # The queue advanced to the second task; progress updated.
    assert html =~ "what are your hours"
    assert html =~ "1 labeled · 1 to go"
    assert html =~ "Recently labeled"

    # Relabel the first one from the labeled list.
    html = lv |> element("#labeled-#{first.id} button", "Relabel") |> render_click()
    assert html =~ "Currently labeled:"

    lv
    |> element("#task-#{first.id} button", "question")
    |> render_click()

    relabeled = Labeling.get_task(scope, first.id)
    assert relabeled.label == %{"choice" => "question"}

    # Export the labeled set.
    conn = get(conn, ~p"/console/labeling/#{project.id}/export")
    assert response_content_type(conn, :jsonl) =~ "application/jsonl"

    lines =
      conn.resp_body
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(lines, &(&1["label"] == %{"choice" => "question"}))
  end

  test "the app monitor queues rated replies into a project", %{conn: conn, scope: scope} do
    {:ok, project} =
      Labeling.create_project(scope, %{"name" => "Review", "label_type" => "text"})

    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Rated App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    conversation = Flux.Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Flux.Chat.send_message(scope, app, conversation, "rate this")
    assert_receive {:done, reply}, 5_000
    {:ok, _} = Flux.Chat.set_feedback(scope, reply.id, :like)

    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}/monitor")

    html =
      lv
      |> element("#feedback-#{reply.id} button", "Label in Review")
      |> render_click()

    assert html =~ "Queued for labeling."

    task = Labeling.next_task(scope, project.id)
    assert task.data["question"] == "rate this"
    assert task.data["answer"] =~ "You said: rate this"
    assert task.source == "feedback"
  end
end
