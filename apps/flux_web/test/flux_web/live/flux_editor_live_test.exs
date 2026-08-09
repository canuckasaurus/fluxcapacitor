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

  test "multi-select aligns and distributes node positions", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, html} = live(conn, ~p"/console/fluxes/#{workflow.id}")
    refute html =~ "align-toolbar"

    render_hook(lv, "select_node", %{"id" => "start", "shift" => false})
    html = render_hook(lv, "select_node", %{"id" => "llm_1", "shift" => true})
    assert html =~ "align-toolbar"

    lv
    |> element(~s(#align-toolbar button[phx-value-mode="top"]))
    |> render_click()

    draft = Workflows.get_workflow(scope, workflow.id)
    positions = Map.new(draft.graph["nodes"], &{&1["id"], &1["position"]})
    assert positions["start"]["y"] == positions["llm_1"]["y"]

    # Third node in: distribute spaces the middles evenly on x.
    html = render_hook(lv, "select_node", %{"id" => "answer_1", "shift" => true})
    assert html =~ "align-toolbar"

    lv
    |> element(~s(#align-toolbar button[phx-value-mode="distribute_h"]))
    |> render_click()

    draft = Workflows.get_workflow(scope, workflow.id)
    positions = Map.new(draft.graph["nodes"], &{&1["id"], &1["position"]})
    [x1, x2, x3] = [positions["start"]["x"], positions["llm_1"]["x"], positions["answer_1"]["x"]]
    assert x2 - x1 == x3 - x2
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

  test "canvas nodes carry explanatory tooltips and docs links", %{
    conn: conn,
    workflow: workflow
  } do
    {:ok, lv, html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    # every node card explains itself and links into the node reference
    assert html =~ "Calls an AI model with your prompt"
    assert html =~ "data-docs-link"
    assert html =~ "/console/docs/node-reference#llm"

    # the config panel repeats the description with a docs link
    html = render_hook(lv, "select_node", %{"id" => "llm_1", "shift" => false})
    assert html =~ "Open the node reference for LLM"
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

    html = lv |> element("#publish-form") |> render_submit(%{"note" => ""})
    assert html =~ "v1"
    assert Workflows.latest_version(scope, workflow.id).version == 1
  end

  test "API modal creates a workflow key", %{conn: conn, workflow: workflow} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("button[phx-click=toggle_api]") |> render_click()
    html = lv |> form("#flux-token-form", %{"lifetime" => "90"}) |> render_submit()

    assert html =~ "flux-"
    assert html =~ "Copy this key now"
    # A 90-day key shows its expiry date; perpetual keys show "never".
    expected = DateTime.utc_now() |> DateTime.add(90, :day) |> Calendar.strftime("%Y-%m-%d")
    assert html =~ expected
  end

  test "triggers modal creates, disables, and deletes a webhook trigger", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("button[phx-click=toggle_triggers]") |> render_click()

    html =
      lv
      |> form("form[phx-submit=create_trigger]", %{"type" => "webhook", "inputs" => ""})
      |> render_submit()

    assert html =~ "/triggers/webhook/wht_"

    [trigger] = Workflows.list_triggers(scope, workflow.id)
    assert trigger.type == :webhook
    assert {:ok, _} = Workflows.fetch_trigger_by_token(trigger.token)

    html = lv |> element("button", "Disable") |> render_click()
    assert html =~ "disabled"
    assert {:error, :not_found} = Workflows.fetch_trigger_by_token(trigger.token)

    lv |> element("button[phx-click=delete_trigger]") |> render_click()
    assert Workflows.list_triggers(scope, workflow.id) == []
  end

  test "triggers modal creates a schedule trigger with static inputs", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("button[phx-click=toggle_triggers]") |> render_click()

    lv
    |> form("form[phx-submit=create_trigger]")
    |> render_change(%{"type" => "schedule"})

    html =
      lv
      |> form("form[phx-submit=create_trigger]", %{
        "type" => "schedule",
        "interval_minutes" => "15",
        "inputs" => ~s({"query": "scheduled"})
      })
      |> render_submit()

    assert html =~ "every 15 min"

    [trigger] = Workflows.list_triggers(scope, workflow.id)
    assert trigger.type == :schedule
    assert trigger.interval_minutes == 15
    assert trigger.inputs == %{"query" => "scheduled"}
    assert trigger.token == nil
  end

  test "trigger creation rejects malformed static inputs JSON", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("button[phx-click=toggle_triggers]") |> render_click()

    html =
      lv
      |> form("form[phx-submit=create_trigger]", %{"type" => "webhook", "inputs" => "not json"})
      |> render_submit()

    assert html =~ "Static inputs must be a JSON object."
    assert Workflows.list_triggers(scope, workflow.id) == []
  end

  test "copy/paste duplicates the selection with edges and fresh ids", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    # Select llm_1 + answer_1 (they are connected in the starter graph).
    render_hook(lv, "marquee_select", %{"ids" => ["llm_1", "answer_1"]})
    render_hook(lv, "copy_selection", %{})
    render_hook(lv, "paste_clipboard", %{})

    saved = Workflows.get_workflow(scope, workflow.id)
    assert Enum.any?(saved.graph["nodes"], &(&1["id"] == "llm_2"))
    assert Enum.any?(saved.graph["nodes"], &(&1["id"] == "answer_2"))

    # The internal edge came along, remapped to the new ids.
    assert Enum.any?(
             saved.graph["edges"],
             &(&1["source"] == "llm_2" and &1["target"] == "answer_2")
           )
  end

  test "version browser restores a published version into the draft", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    wire_echo(scope, workflow)
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("#publish-form") |> render_submit(%{"note" => ""})

    # Mutate the draft after publishing.
    render_click(lv, "add_node", %{"type" => "template"})

    assert Enum.any?(
             Workflows.get_workflow(scope, workflow.id).graph["nodes"],
             &(&1["type"] == "template")
           )

    lv |> element("button[phx-click=toggle_versions]") |> render_click()
    lv |> element("button", "Restore to draft") |> render_click()

    restored = Workflows.get_workflow(scope, workflow.id)
    refute Enum.any?(restored.graph["nodes"], &(&1["type"] == "template"))

    # Undo brings the mutated draft back.
    render_hook(lv, "undo", %{})

    assert Enum.any?(
             Workflows.get_workflow(scope, workflow.id).graph["nodes"],
             &(&1["type"] == "template")
           )
  end

  test "per-node debug run executes one node with a mock pool", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    wire_echo(scope, workflow)
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_hook(lv, "select_node", %{"id" => "llm_1", "shift" => false})

    html =
      lv
      |> form("form[phx-submit=debug_node]", %{"mock" => %{"start.query" => "debug ping"}})
      |> render_submit()

    assert html =~ "You said: debug ping"
  end

  test "auto-layout arranges nodes into depth columns and renders the minimap", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    {:ok, lv, html} = live(conn, ~p"/console/fluxes/#{workflow.id}")
    assert html =~ "minimap"

    # Scramble a position, then tidy.
    render_hook(lv, "node_moved", %{"id" => "llm_1", "x" => 40, "y" => 900})
    lv |> element("button", "Tidy") |> render_click()

    saved = Workflows.get_workflow(scope, workflow.id)
    positions = Map.new(saved.graph["nodes"], &{&1["id"], &1["position"]})

    # start (depth 0) → llm_1 (depth 1) → answer_1 (depth 2), 300px columns.
    assert positions["start"]["x"] == 60
    assert positions["llm_1"]["x"] == 360
    assert positions["answer_1"]["x"] == 660
  end

  test "palette search filters addable node types", %{conn: conn, workflow: workflow} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    html =
      lv
      |> form("form[phx-change=palette_search]")
      |> render_change(%{"palette_query" => "class"})

    assert html =~ "Classifier"
    refute html =~ ">HTTP Request<"
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

  test "extracting a selection makes a new flux with externalized inputs", %{
    conn: conn,
    workflow: workflow,
    scope: scope
  } do
    workflow = wire_echo(scope, workflow)
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    # Select the llm + answer nodes and extract them.
    render_hook(lv, "marquee_select", %{"ids" => ["llm_1", "answer_1"]})
    render_click(lv, "extract_subflux", %{})

    extracted = Enum.find(Workflows.list_workflows(scope), &(&1.name =~ "extracted"))
    assert extracted != nil

    node_ids = Enum.map(extracted.graph["nodes"], & &1["id"])
    assert "start" in node_ids and "llm_1" in node_ids and "answer_1" in node_ids

    # {{start.query}} referenced the parent's start → became a start
    # variable of the extracted flux, and the prompt was rewritten.
    start = Enum.find(extracted.graph["nodes"], &(&1["id"] == "start"))
    assert [%{"name" => "start_query"}] = start["config"]["variables"]

    llm = Enum.find(extracted.graph["nodes"], &(&1["id"] == "llm_1"))
    assert llm["config"]["prompt"] == "{{start.start_query}}"

    # Internal references survive untouched.
    answer = Enum.find(extracted.graph["nodes"], &(&1["id"] == "answer_1"))
    assert answer["config"]["answer"] == "{{llm_1.text}}"
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
