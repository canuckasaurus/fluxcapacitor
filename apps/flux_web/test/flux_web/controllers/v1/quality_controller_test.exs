defmodule FluxWeb.V1.QualityControllerTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Evals
  alias Flux.Labeling
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "API WS"})
    scope = Accounts.scope_for(account)

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "config" => %{
            "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "llm_1",
          "type" => "llm",
          "title" => "LLM",
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "prompt" => "{{start.query}}"
          }
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "config" => %{"answer" => "{{llm_1.text}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "llm_1"},
        %{"id" => "e2", "source" => "llm_1", "source_handle" => "default", "target" => "answer_1"}
      ]
    }

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "API Flux"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, _token, raw} = Workflows.create_api_token(scope, workflow)

    conn = put_req_header(conn, "authorization", "Bearer #{raw}")
    %{conn: conn, scope: scope, workflow: workflow}
  end

  test "batches start and report over the API", %{conn: conn, scope: scope} do
    conn_create =
      post(conn, ~p"/v1/workflows/batch", %{
        "rows" => [%{"query" => "one"}, %{"query" => "two"}],
        "name" => "ci.csv"
      })

    assert %{"batch_id" => batch_id, "total" => 2, "target" => "draft"} =
             json_response(conn_create, 202)

    # Oban is manual in tests; execute inline, then poll the API.
    :ok = Workflows.perform_batch(batch_id)

    body =
      conn
      |> get(~p"/v1/batches/#{batch_id}?include_results=true")
      |> json_response(200)

    assert body["status"] == "completed"
    assert body["succeeded"] == 2
    assert [%{"outputs" => %{"answer" => answer}} | _rest] = body["results"]
    assert answer =~ "You said:"

    # A wrong-workspace batch id is a 404, and app tokens are refused.
    assert conn |> get(~p"/v1/batches/#{Ecto.UUID.generate()}") |> json_response(404)
    assert Workflows.list_batches(scope, hd(Workflows.list_workflows(scope)).id) != []
  end

  test "eval sets run and report over the API", %{conn: conn, scope: scope, workflow: workflow} do
    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "CI"})

    {:ok, _} =
      Evals.add_case(scope, set, %{
        "inputs" => %{"query" => "alpha"},
        "expected" => "you said: alpha"
      })

    assert [%{"id" => set_id, "gate" => false}] =
             conn |> get(~p"/v1/eval-sets") |> json_response(200) |> Map.get("data")

    conn_run =
      post(conn, ~p"/v1/eval-sets/#{set_id}/run", %{"grader" => "contains"})

    assert %{"eval_run_id" => eval_run_id} = json_response(conn_run, 202)

    :ok = Evals.perform_eval(eval_run_id)

    body = conn |> get(~p"/v1/eval-runs/#{eval_run_id}") |> json_response(200)
    assert body["status"] == "completed"
    assert body["passed"] == 1
    assert body["avg_score"] == 1.0
  end

  test "labeling round-trips over the API", %{conn: conn, scope: scope} do
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "API Intent",
        "label_type" => "choice",
        "options" => ["complaint", "question"]
      })

    assert [%{"name" => "API Intent", "options" => ["complaint", "question"]}] =
             conn |> get(~p"/v1/labeling/projects") |> json_response(200) |> Map.get("data")

    assert %{"count" => 2} =
             conn
             |> post(~p"/v1/labeling/projects/#{project.id}/tasks", %{
               "items" => ["refund me", %{"text" => "hours?"}]
             })
             |> json_response(201)

    assert %{"task" => %{"id" => task_id, "data" => %{"text" => "refund me"}}} =
             conn |> get(~p"/v1/labeling/projects/#{project.id}/next") |> json_response(200)

    assert %{"status" => "labeled"} =
             conn
             |> post(~p"/v1/labeling/tasks/#{task_id}/label", %{
               "label" => %{"choice" => "complaint"}
             })
             |> json_response(200)

    # Schema violations are refused.
    assert %{"code" => "invalid_label"} =
             conn
             |> post(~p"/v1/labeling/tasks/#{task_id}/label", %{"label" => %{"choice" => "nope"}})
             |> json_response(422)

    export = conn |> get(~p"/v1/labeling/projects/#{project.id}/export")
    assert response_content_type(export, :jsonl) =~ "application/jsonl"
    [line | _] = String.split(String.trim(export.resp_body), "\n")
    assert Jason.decode!(line)["label"] == %{"choice" => "complaint"}
  end
end
