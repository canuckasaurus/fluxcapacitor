defmodule FluxWeb.V1.WorkflowRunControllerTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Flux API WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "API Flux"})

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
    {:ok, _token, raw} = Workflows.create_api_token(scope, workflow)

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{raw}"),
      scope: scope,
      workflow: workflow,
      raw_token: raw
    }
  end

  defp publish!(scope, workflow), do: {:ok, _version} = Workflows.publish(scope, workflow)

  test "paused runs report their prompt and resume over the API", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    graph =
      Map.update!(workflow.graph, "nodes", fn nodes ->
        nodes ++
          [
            %{
              "id" => "ask",
              "type" => "human_input",
              "title" => "Approve",
              "position" => %{"x" => 900, "y" => 100},
              "config" => %{"prompt" => "Continue?", "options" => []}
            },
            %{
              "id" => "t",
              "type" => "template",
              "title" => "Done",
              "position" => %{"x" => 1200, "y" => 100},
              "config" => %{"template" => "resumed with {{ask.output}}"}
            }
          ]
      end)

    # Rewire: answer → ask → template.
    graph =
      Map.update!(graph, "edges", fn edges ->
        edges ++
          [
            %{
              "id" => "ea",
              "source" => "answer_1",
              "source_handle" => "default",
              "target" => "ask"
            },
            %{"id" => "et", "source" => "ask", "source_handle" => "default", "target" => "t"}
          ]
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    publish!(scope, workflow)

    body =
      conn
      |> post(~p"/v1/workflows/run", %{
        "inputs" => %{"query" => "ship it"},
        "response_mode" => "blocking"
      })
      |> json_response(200)

    assert body["data"]["status"] == "paused"
    assert body["data"]["paused_prompt"]["prompt"] == "Continue?"
    run_id = body["data"]["id"]

    body =
      conn
      |> post(~p"/v1/workflows/runs/#{run_id}/resume", %{
        "input" => "yes",
        "response_mode" => "blocking"
      })
      |> json_response(200)

    assert body["data"]["status"] == "succeeded"
    assert body["data"]["outputs"]["output"] == "resumed with yes"

    assert conn
           |> post(~p"/v1/workflows/runs/#{run_id}/resume", %{"input" => "again"})
           |> json_response(400)
           |> Map.fetch!("code") == "not_paused"
  end

  test "rejects missing or invalid tokens" do
    conn = build_conn() |> post(~p"/v1/workflows/run", %{"inputs" => %{}})
    assert conn.status == 401

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer flux-invalid")
      |> post(~p"/v1/workflows/run", %{"inputs" => %{}})

    assert conn.status == 401
  end

  test "rejects app tokens on the workflow endpoint", %{scope: scope} do
    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Chat App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _token, app_raw} = Flux.Chat.create_api_token(scope, app)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{app_raw}")
      |> post(~p"/v1/workflows/run", %{"inputs" => %{}})

    assert json_response(conn, 403)["code"] == "invalid_token_kind"
  end

  test "requires a published version", %{conn: conn} do
    conn = post(conn, ~p"/v1/workflows/run", %{"inputs" => %{"query" => "hi"}})
    assert json_response(conn, 400)["code"] == "workflow_not_published"
  end

  test "blocking mode returns outputs of the published version", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    publish!(scope, workflow)

    conn =
      post(conn, ~p"/v1/workflows/run", %{
        "inputs" => %{"query" => "ping"},
        "response_mode" => "blocking"
      })

    body = json_response(conn, 200)
    assert body["data"]["status"] == "succeeded"
    assert body["data"]["outputs"]["answer"] =~ "You said: ping"
    assert body["data"]["elapsed_time"] >= 0
    assert body["workflow_run_id"] == body["data"]["id"]
  end

  test "streaming mode emits the portable event sequence", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    publish!(scope, workflow)

    conn = post(conn, ~p"/v1/workflows/run", %{"inputs" => %{"query" => "stream me"}})
    assert conn.state == :chunked

    events = parse_sse(conn.resp_body)
    kinds = Enum.map(events, & &1["event"])

    assert List.first(kinds) == "workflow_started"
    assert "node_started" in kinds
    assert "text_chunk" in kinds
    assert "node_finished" in kinds
    assert List.last(kinds) == "workflow_finished"

    text =
      events
      |> Enum.filter(&(&1["event"] == "text_chunk"))
      |> Enum.map_join("", & &1["data"]["text"])

    assert text =~ "You said: stream me"

    finished = List.last(events)
    assert finished["data"]["status"] == "succeeded"
    assert finished["data"]["outputs"]["answer"] =~ "You said: stream me"
  end

  test "missing required inputs fail the run", %{conn: conn, scope: scope, workflow: workflow} do
    publish!(scope, workflow)

    conn =
      post(conn, ~p"/v1/workflows/run", %{"inputs" => %{}, "response_mode" => "blocking"})

    body = json_response(conn, 200)
    assert body["data"]["status"] == "failed"
    assert body["data"]["error"] =~ "query is required"
  end

  test "runs the published snapshot, not the mutated draft", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    publish!(scope, workflow)

    # Break the draft AFTER publishing; the API must still run the snapshot.
    {:ok, _} = Workflows.update_draft(scope, workflow, %{"nodes" => [], "edges" => []})

    conn =
      post(conn, ~p"/v1/workflows/run", %{
        "inputs" => %{"query" => "snapshot"},
        "response_mode" => "blocking"
      })

    assert json_response(conn, 200)["data"]["status"] == "succeeded"
  end

  defp parse_sse(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end
end
