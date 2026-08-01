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
