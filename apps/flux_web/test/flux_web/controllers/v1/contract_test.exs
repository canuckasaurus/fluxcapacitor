defmodule FluxWeb.V1.ContractTest do
  @moduledoc """
  OpenAPI contract tests: every /v1 JSON response is validated against
  `FluxWeb.V1.ApiSpec`. Schemas use additionalProperties: false, so adding,
  removing, or renaming a response field fails here.
  """
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import OpenApiSpex.TestAssertions

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Contract WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Contract App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _token, app_token} = Chat.create_api_token(scope, app)

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{app_token}"),
      scope: scope,
      app: app,
      api_spec: FluxWeb.V1.ApiSpec.spec()
    }
  end

  defp flux_conn(scope) do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Contract Flux"})

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
    {:ok, _version} = Workflows.publish(scope, workflow)
    {:ok, _token, raw} = Workflows.create_api_token(scope, workflow)
    build_conn() |> put_req_header("authorization", "Bearer #{raw}")
  end

  test "the datasets surface matches its schemas end to end", %{conn: conn, api_spec: spec} do
    created =
      conn |> post(~p"/v1/datasets", %{"name" => "Contract KB"}) |> json_response(200)

    assert_schema(created, "DatasetCreated", spec)
    dataset_id = created["id"]

    body = conn |> get(~p"/v1/datasets") |> json_response(200)
    assert_schema(body, "DatasetList", spec)

    doc =
      conn
      |> post(~p"/v1/datasets/#{dataset_id}/document/create-by-text", %{
        "name" => "contract.md",
        "text" => "Contracts protect API consumers."
      })
      |> json_response(200)

    assert_schema(doc, "DocumentCreated", spec)
    Oban.drain_queue(queue: :ingest)

    body = conn |> get(~p"/v1/datasets/#{dataset_id}/documents") |> json_response(200)
    assert_schema(body, "DocumentList", spec)
    [%{"id" => document_id}] = body["data"]

    body =
      conn
      |> get(~p"/v1/datasets/#{dataset_id}/documents/#{document_id}/segments")
      |> json_response(200)

    assert_schema(body, "SegmentList", spec)

    body =
      conn
      |> post(~p"/v1/datasets/#{dataset_id}/retrieve", %{"query" => "what protects consumers?"})
      |> json_response(200)

    assert_schema(body, "RetrieveResult", spec)
    assert body["records"] != []

    body =
      conn
      |> delete(~p"/v1/datasets/#{dataset_id}/documents/#{document_id}")
      |> json_response(200)

    assert_schema(body, "Result", spec)

    body = conn |> delete(~p"/v1/datasets/#{dataset_id}") |> json_response(200)
    assert_schema(body, "Result", spec)
  end

  test "chat-messages blocking response matches ChatMessage", %{conn: conn, api_spec: spec} do
    body =
      conn
      |> post(~p"/v1/chat-messages", %{"query" => "contract", "response_mode" => "blocking"})
      |> json_response(200)

    assert_schema(body, "ChatMessage", spec)
  end

  test "completion-messages blocking response matches ChatMessage", %{
    scope: scope,
    api_spec: spec
  } do
    {:ok, completion_app} =
      Chat.create_app(scope, %{
        "name" => "Contract Completion",
        "mode" => "completion",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "prompt_template" => "Echo {{inputs.q}}"
      })

    {:ok, _token, token} = Chat.create_api_token(scope, completion_app)

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/v1/completion-messages", %{
        "inputs" => %{"q" => "hi"},
        "response_mode" => "blocking"
      })
      |> json_response(200)

    assert_schema(body, "ChatMessage", spec)
  end

  test "workflows/run blocking response matches WorkflowRun", %{scope: scope, api_spec: spec} do
    body =
      flux_conn(scope)
      |> post(~p"/v1/workflows/run", %{
        "inputs" => %{"query" => "contract"},
        "response_mode" => "blocking"
      })
      |> json_response(200)

    assert_schema(body, "WorkflowRun", spec)
  end

  test "parameters matches Parameters (with and without input form)", %{
    conn: conn,
    scope: scope,
    app: app,
    api_spec: spec
  } do
    body = conn |> get(~p"/v1/parameters") |> json_response(200)
    assert_schema(body, "Parameters", spec)

    {:ok, _app} =
      Chat.update_app(scope, app, %{
        "input_form" => [
          %{"variable" => "text", "label" => "Text", "type" => "paragraph", "required" => true}
        ]
      })

    body = conn |> get(~p"/v1/parameters") |> json_response(200)
    assert_schema(body, "Parameters", spec)
  end

  test "conversations, messages, stop, feedback, rename, delete, meta all match", %{
    conn: conn,
    api_spec: spec
  } do
    first =
      conn
      |> post(~p"/v1/chat-messages", %{"query" => "seed", "response_mode" => "blocking"})
      |> json_response(200)

    body = conn |> get(~p"/v1/conversations") |> json_response(200)
    assert_schema(body, "ConversationList", spec)
    [%{"id" => conversation_id}] = body["data"]

    body = conn |> get(~p"/v1/messages?conversation_id=#{conversation_id}") |> json_response(200)
    assert_schema(body, "MessageList", spec)

    body =
      conn
      |> post(~p"/v1/messages/#{first["message_id"]}/feedbacks", %{"rating" => "like"})
      |> json_response(200)

    assert_schema(body, "Result", spec)

    body =
      conn
      |> post(~p"/v1/conversations/#{conversation_id}/name", %{"name" => "Renamed"})
      |> json_response(200)

    assert_schema(body, "ConversationRenamed", spec)

    body = conn |> get(~p"/v1/meta") |> json_response(200)
    assert_schema(body, "Meta", spec)

    body = conn |> delete(~p"/v1/conversations/#{conversation_id}") |> json_response(200)
    assert_schema(body, "Result", spec)
  end

  test "files/upload matches FileUpload", %{conn: conn, api_spec: spec} do
    upload = %Plug.Upload{
      path: write_tmp!("contract upload body"),
      filename: "contract.txt",
      content_type: "text/plain"
    }

    body = conn |> post(~p"/v1/files/upload", %{"file" => upload}) |> json_response(200)
    assert_schema(body, "FileUpload", spec)
  end

  test "the quality loop (batches, evals, labeling) matches its schemas", %{
    conn: conn,
    scope: scope,
    api_spec: spec
  } do
    fconn = flux_conn(scope)

    started =
      fconn
      |> post(~p"/v1/workflows/batch", %{"rows" => [%{"query" => "one"}]})
      |> json_response(202)

    assert_schema(started, "BatchStarted", spec)
    :ok = Workflows.perform_batch(started["batch_id"])

    body =
      fconn
      |> get(~p"/v1/batches/#{started["batch_id"]}?include_results=true")
      |> json_response(200)

    assert_schema(body, "BatchStatus", spec)

    workflow = scope |> Workflows.list_workflows() |> List.first()
    {:ok, set} = Flux.Evals.create_set(scope, workflow, %{"name" => "Contract set"})

    {:ok, _} =
      Flux.Evals.add_case(scope, set, %{"inputs" => %{"query" => "hi"}, "expected" => "hi"})

    body = fconn |> get(~p"/v1/eval-sets") |> json_response(200)
    assert_schema(body, "EvalSetList", spec)

    eval_started =
      fconn
      |> post(~p"/v1/eval-sets/#{set.id}/run", %{"grader" => "contains"})
      |> json_response(202)

    assert_schema(eval_started, "EvalStarted", spec)
    :ok = Flux.Evals.perform_eval(eval_started["eval_run_id"])

    body = fconn |> get(~p"/v1/eval-runs/#{eval_started["eval_run_id"]}") |> json_response(200)
    assert_schema(body, "EvalRunStatus", spec)

    {:ok, project} =
      Flux.Labeling.create_project(scope, %{
        "name" => "Contract labels",
        "label_type" => "choice",
        "options" => ["yes", "no"]
      })

    body = conn |> get(~p"/v1/labeling/projects") |> json_response(200)
    assert_schema(body, "LabelingProjectList", spec)

    created =
      conn
      |> post(~p"/v1/labeling/projects/#{project.id}/tasks", %{"items" => ["label me"]})
      |> json_response(201)

    assert_schema(created, "LabelingTasksCreated", spec)

    body = conn |> get(~p"/v1/labeling/projects/#{project.id}/next") |> json_response(200)
    assert_schema(body, "LabelingNextTask", spec)
    task_id = body["task"]["id"]

    body =
      conn
      |> post(~p"/v1/labeling/tasks/#{task_id}/label", %{"label" => %{"choice" => "yes"}})
      |> json_response(200)

    assert_schema(body, "LabelingLabeled", spec)

    # Drained queue: null task is also in contract.
    body = conn |> get(~p"/v1/labeling/projects/#{project.id}/next") |> json_response(200)
    assert_schema(body, "LabelingNextTask", spec)
    assert body["task"] == nil

    # Quality errors carry the shared Error shape.
    body = fconn |> post(~p"/v1/workflows/batch", %{"rows" => []}) |> json_response(400)
    assert_schema(body, "Error", spec)
  end

  test "GET /v1/spec serves the OpenAPI document", %{conn: conn} do
    body = conn |> get(~p"/v1/spec") |> json_response(200)

    assert body["openapi"] =~ "3."
    assert body["info"]["title"] == "FluxCapacitor Service API"
    assert body["paths"]["/workflows/run"]["post"]["operationId"] == "post_workflows_run"
    assert body["components"]["schemas"]["WorkflowRun"]
    assert body["components"]["schemas"]["ChatMessage"]
  end

  test "error responses match Error", %{conn: conn, api_spec: spec} do
    body = conn |> post(~p"/v1/chat-messages", %{}) |> json_response(400)
    assert_schema(body, "Error", spec)

    body =
      conn |> get(~p"/v1/messages?conversation_id=#{Ecto.UUID.generate()}") |> json_response(404)

    assert_schema(body, "Error", spec)
  end

  defp write_tmp!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "flux-contract-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, content)
    path
  end
end
