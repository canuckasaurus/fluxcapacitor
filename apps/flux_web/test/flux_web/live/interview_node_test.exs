defmodule FluxWeb.InterviewNodeTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Interviews
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Interview WS"})
    scope = Accounts.scope_for(account)

    {:ok, interview} =
      Interviews.create(scope, %{
        "name" => "Intake",
        "intro" => "About {{start.matter}}:",
        "questions" => [
          %{"name" => "client_name", "label" => "Client name", "required" => true},
          %{"name" => "age", "label" => "Age", "type" => "number", "required" => true},
          %{"name" => "urgent", "label" => "Urgent?", "type" => "boolean"}
        ]
      })

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Intake Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [%{"name" => "matter", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "interview_1",
          "type" => "interview",
          "title" => "Intake",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{"interview_id" => interview.id}
        },
        %{
          "id" => "end",
          "type" => "end",
          "title" => "End",
          "position" => %{"x" => 600, "y" => 0},
          "config" => %{
            "outputs" => [
              %{"key" => "who", "value" => "{{interview_1.client_name}}"},
              %{"key" => "age", "value" => "{{interview_1.age}}"}
            ]
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "start",
          "source_handle" => "default",
          "target" => "interview_1"
        },
        %{
          "id" => "e2",
          "source" => "interview_1",
          "source_handle" => "default",
          "target" => "end"
        }
      ]
    }

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)

    %{conn: log_in_account(conn, account), scope: scope, workflow: workflow}
  end

  test "an interview node pauses with the questions and resumes validated", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, run} = Workflows.start_run(scope, workflow, %{"matter" => "the will"})
    assert_receive {:run_finished, paused}, 5_000

    assert paused.status == :paused
    assert paused.snapshot["prompt"]["prompt"] == "About the will:"
    assert paused.snapshot["prompt"]["interview"] == "Intake"
    assert [%{"name" => "client_name"} | _rest] = paused.snapshot["prompt"]["questions"]

    # Bad answers bounce with per-question errors and the run stays paused.
    assert {:error, {:invalid_answers, errors}} =
             Workflows.resume_run_with_params(scope, run.id, %{"age" => "old"})

    assert errors["client_name"] == "is required"
    assert errors["age"] == "must be a number"

    # Valid answers resume; each lands as an output key downstream.
    {:ok, _resumed} =
      Workflows.resume_run_with_params(scope, run.id, %{
        "client_name" => "Clara Clayton",
        "age" => "32",
        "urgent" => "on"
      })

    assert_receive {:run_finished, finished}, 5_000
    assert finished.status == :succeeded
    assert finished.outputs == %{"who" => "Clara Clayton", "age" => "32"}
  end

  test "interview progress reports step X of Y across pause nodes" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    graph = %{
      "nodes" => [
        %{"type" => "start"},
        %{"id" => "iv1", "type" => "interview"},
        %{"id" => "hi1", "type" => "human_input"},
        %{"id" => "iv2", "type" => "interview"}
      ]
    }

    first_pause = %{node_executions: [%{"node_id" => "iv1", "node_type" => "interview"}]}

    html =
      render_component(&FluxWeb.InterviewComponents.interview_progress/1,
        run: first_pause,
        graph: graph
      )

    assert html =~ "Step 1 of 3"

    second_pause = %{
      node_executions: [
        %{"node_id" => "iv1", "node_type" => "interview"},
        %{"node_id" => "hi1", "node_type" => "human_input"}
      ]
    }

    html =
      render_component(&FluxWeb.InterviewComponents.interview_progress/1,
        run: second_pause,
        graph: graph
      )

    assert html =~ "Step 2 of 3"

    # A single pause node renders no stepper at all.
    single = %{"nodes" => [%{"id" => "iv1", "type" => "interview"}]}

    html =
      render_component(&FluxWeb.InterviewComponents.interview_progress/1,
        run: first_pause,
        graph: single
      )

    refute html =~ "Step"
  end

  test "the /v1 resume endpoint validates interview answers", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    {:ok, _version} = Workflows.publish(scope, workflow)
    {:ok, _token, raw_token} = Workflows.create_api_token(scope, workflow)

    {:ok, run} = Workflows.start_run(scope, workflow, %{"matter" => "a deed"})
    assert_receive {:run_finished, %{status: :paused}}, 5_000

    api = put_req_header(conn, "authorization", "Bearer #{raw_token}")

    bad =
      post(api, ~p"/v1/workflows/runs/#{run.id}/resume", %{
        "inputs" => %{"age" => "not a number"},
        "response_mode" => "blocking"
      })

    assert bad.status == 422
    body = json_response(bad, 422)
    assert body["code"] == "invalid_answers"
    assert body["errors"]["client_name"] == "is required"

    good =
      post(api, ~p"/v1/workflows/runs/#{run.id}/resume", %{
        "inputs" => %{"client_name" => "Seamus", "age" => "40"},
        "response_mode" => "blocking"
      })

    assert %{"data" => %{"status" => "succeeded", "outputs" => outputs}} =
             json_response(good, 200)

    assert outputs["who"] == "Seamus"
  end
end
