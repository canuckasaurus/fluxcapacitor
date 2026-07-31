defmodule FluxWeb.FluxEditorLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Flux UI WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "UI Flux"})
    %{conn: log_in_account(conn, account), workflow: workflow, scope: scope}
  end

  defp wire_echo(scope, workflow) do
    graph =
      update_in(workflow.graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node ->
            node
            |> put_in(["config", "provider_plugin_id"], "echo")
            |> put_in(["config", "model"], "echo-1")

          node ->
            node
        end)
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    workflow
  end

  test "importing a portable DSL creates a flux and opens the editor", %{conn: conn, scope: scope} do
    dsl =
      Path.expand("../../../../flux/test/support/fixtures/dsl", __DIR__)
      |> Path.join("conditional_hello_branching_workflow.yml")
      |> File.read!()

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")
    lv |> element("button", "Import DSL") |> render_click()

    assert {:error, {:live_redirect, %{to: "/console/fluxes/" <> _id}}} =
             lv |> form("form[phx-submit=import]", %{"dsl" => dsl}) |> render_submit()

    imported = Enum.find(Workflows.list_workflows(scope), &(&1.name == "if-else"))
    assert imported != nil
    assert Enum.count(imported.graph["nodes"]) == 4
  end

  test "fluxes index lists workflows and creates new ones", %{conn: conn, workflow: workflow} do
    {:ok, lv, html} = live(conn, ~p"/console/fluxes")
    assert html =~ workflow.name
    assert html =~ "Open canvas"

    lv |> element("button", "New Flux") |> render_click()

    assert {:error, {:live_redirect, %{to: "/console/fluxes/" <> _id}}} =
             lv
             |> form("#workflow-form", %{"workflow" => %{"name" => "Second Flux"}})
             |> render_submit()
  end

  test "editor renders the starter graph", %{conn: conn, workflow: workflow} do
    {:ok, _lv, html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    assert html =~ "node-start"
    assert html =~ "node-llm_1"
    assert html =~ "node-answer_1"
    assert html =~ "edge-layer"
  end

  test "selecting a node opens its config panel and edits save", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    html = render_hook(lv, "select_node", %{"id" => "answer_1", "shift" => false})
    assert html =~ "Answer"

    lv
    |> element("form[phx-change=update_node]")
    |> render_change(%{"title" => "Final Answer", "answer" => "OUT: {{llm_1.text}}"})

    {:ok, saved} = {:ok, Workflows.get_workflow(scope, workflow.id)}
    answer = Enum.find(saved.graph["nodes"], &(&1["id"] == "answer_1"))
    assert answer["title"] == "Final Answer"
    assert answer["config"]["answer"] == "OUT: {{llm_1.text}}"
  end

  test "add node, move node, connect, and delete edge mutate the draft", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_click(lv, "add_node", %{"type" => "template"})
    saved = Workflows.get_workflow(scope, workflow.id)
    assert Enum.any?(saved.graph["nodes"], &(&1["type"] == "template"))

    render_hook(lv, "node_moved", %{"id" => "llm_1", "x" => 500, "y" => 300})
    saved = Workflows.get_workflow(scope, workflow.id)
    llm = Enum.find(saved.graph["nodes"], &(&1["id"] == "llm_1"))
    assert llm["position"] == %{"x" => 500, "y" => 300}

    render_hook(lv, "connect", %{
      "source" => "template_1",
      "source_handle" => "default",
      "target" => "answer_1"
    })

    saved = Workflows.get_workflow(scope, workflow.id)
    assert Enum.any?(saved.graph["edges"], &(&1["source"] == "template_1"))

    render_click(lv, "delete_edge", %{"id" => "edge_template_1_default_answer_1"})
    saved = Workflows.get_workflow(scope, workflow.id)
    refute Enum.any?(saved.graph["edges"], &(&1["source"] == "template_1"))
  end

  test "running a draft streams to the run panel", %{conn: conn, workflow: workflow, scope: scope} do
    wire_echo(scope, workflow)

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("button", "Run") |> render_click()

    lv
    |> form("form[phx-submit=start_run]", %{"inputs" => %{"query" => "canvas ping"}})
    |> render_submit()

    html = poll_until(lv, "You said: canvas ping", 50)
    assert html =~ "You said: canvas ping"

    # The final status renders when {:run_finished, run} lands, which can
    # trail the last streamed chunk — poll for it separately.
    assert poll_until(lv, "succeeded", 50) =~ "succeeded"
  end

  test "publish creates a version and shows the badge", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    wire_echo(scope, workflow)

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    html = lv |> element("button", "Publish") |> render_click()
    assert html =~ "v1"
    assert Workflows.latest_version(scope, workflow.id).version == 1
  end

  test "API modal creates a workflow key", %{conn: conn, workflow: workflow} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("button[phx-click=toggle_api]") |> render_click()
    html = lv |> element("button", "Create API key") |> render_click()

    assert html =~ "flux-"
    assert html =~ "Copy this key now"
  end

  test "deleting the start node is rejected", %{conn: conn, workflow: workflow, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_click(lv, "delete_node", %{"id" => "start"})
    saved = Workflows.get_workflow(scope, workflow.id)
    assert Enum.any?(saved.graph["nodes"], &(&1["type"] == "start"))
  end

  test "undo and redo restore graph states", %{conn: conn, workflow: workflow, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_click(lv, "add_node", %{"type" => "template"})

    assert Enum.any?(
             Workflows.get_workflow(scope, workflow.id).graph["nodes"],
             &(&1["type"] == "template")
           )

    render_hook(lv, "undo", %{})

    refute Enum.any?(
             Workflows.get_workflow(scope, workflow.id).graph["nodes"],
             &(&1["type"] == "template")
           )

    render_hook(lv, "redo", %{})

    assert Enum.any?(
             Workflows.get_workflow(scope, workflow.id).graph["nodes"],
             &(&1["type"] == "template")
           )
  end

  test "delete_selection removes the selected node", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_hook(lv, "select_node", %{"id" => "answer_1", "shift" => false})
    render_hook(lv, "delete_selection", %{})

    refute Enum.any?(
             Workflows.get_workflow(scope, workflow.id).graph["nodes"],
             &(&1["id"] == "answer_1")
           )
  end

  test "shift-select builds a multi-selection that deletes together (start survives)", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_hook(lv, "select_node", %{"id" => "llm_1", "shift" => false})
    render_hook(lv, "select_node", %{"id" => "answer_1", "shift" => true})
    render_hook(lv, "select_node", %{"id" => "start", "shift" => true})
    render_hook(lv, "delete_selection", %{})

    remaining = Enum.map(Workflows.get_workflow(scope, workflow.id).graph["nodes"], & &1["id"])
    assert remaining == ["start"]
  end

  test "nodes_moved updates several positions in one undoable step", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_hook(lv, "nodes_moved", %{
      "moves" => [
        %{"id" => "llm_1", "x" => 400, "y" => 111},
        %{"id" => "answer_1", "x" => 720, "y" => 222}
      ]
    })

    graph = Workflows.get_workflow(scope, workflow.id).graph
    assert Enum.find(graph["nodes"], &(&1["id"] == "llm_1"))["position"]["y"] == 111
    assert Enum.find(graph["nodes"], &(&1["id"] == "answer_1"))["position"]["y"] == 222

    # One drag = one undo step: both nodes snap back together.
    render_hook(lv, "undo", %{})
    graph = Workflows.get_workflow(scope, workflow.id).graph
    assert Enum.find(graph["nodes"], &(&1["id"] == "llm_1"))["position"]["y"] == 200
    assert Enum.find(graph["nodes"], &(&1["id"] == "answer_1"))["position"]["y"] == 220
  end

  test "marquee_select selects only known nodes", %{conn: conn, workflow: workflow} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    html =
      render_hook(lv, "marquee_select", %{"ids" => ["llm_1", "answer_1", "ghost"]})

    assert html =~ ~s(id="node-llm_1" data-node="llm_1" data-selected)
    assert html =~ ~s(id="node-answer_1" data-node="answer_1" data-selected)
    refute html =~ ~s(id="node-start" data-node="start" data-selected)
  end

  test "edges select on click and Delete removes them", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_click(lv, "select_edge", %{"id" => "edge_llm_1_answer_1"})
    render_hook(lv, "delete_selection", %{})

    edges = Workflows.get_workflow(scope, workflow.id).graph["edges"]
    refute Enum.any?(edges, &(&1["id"] == "edge_llm_1_answer_1"))
    assert Enum.any?(edges, &(&1["id"] == "edge_start_llm_1"))
  end

  test "duplicate_node copies config at an offset", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_click(lv, "duplicate_node", %{"id" => "llm_1"})

    saved = Workflows.get_workflow(scope, workflow.id)
    llm_nodes = Enum.filter(saved.graph["nodes"], &(&1["type"] == "llm"))
    assert length(llm_nodes) == 2

    [original, copy] = Enum.sort_by(llm_nodes, & &1["id"])
    assert copy["config"]["prompt"] == original["config"]["prompt"]
    assert copy["position"]["x"] == original["position"]["x"] + 40
  end

  test "rename updates the workflow name", %{conn: conn, workflow: workflow, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv
    |> form("form[phx-submit=rename]", %{"name" => "Renamed Flux"})
    |> render_submit()

    assert Workflows.get_workflow(scope, workflow.id).name == "Renamed Flux"
  end

  test "zoom cycles through levels and resets", %{conn: conn, workflow: workflow} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    html = render_click(lv, "zoom", %{"dir" => "in"})
    assert html =~ "125%"

    html = render_click(lv, "zoom", %{"dir" => "reset"})
    assert html =~ "100%"

    html = render_click(lv, "zoom", %{"dir" => "out"})
    assert html =~ "80%"
  end

  test "history drawer lists runs with traces", %{conn: conn, workflow: workflow, scope: scope} do
    workflow = wire_echo(scope, workflow)

    {:ok, run} = Workflows.start_run(scope, workflow, %{"query" => "trace me"})
    assert_receive {:run_finished, _run}, 5_000

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    html = lv |> element("button", "History") |> render_click()
    assert html =~ "Run history"
    assert html =~ "succeeded"

    html = render_click(lv, "select_run", %{"id" => run.id})
    assert html =~ "trace me"
    assert html =~ "· llm ·"
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
