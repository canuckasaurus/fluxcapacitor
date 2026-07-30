defmodule FluxWeb.V1.CompletionFilesTriggersTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "CFT WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Completion App",
        "mode" => "completion",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "prompt_template" => "Summarize: {{inputs.text}}",
        "input_form" => [%{"name" => "text", "type" => "paragraph", "required" => true}]
      })

    {:ok, _t, raw} = Chat.create_api_token(scope, app)
    %{conn: put_req_header(conn, "authorization", "Bearer #{raw}"), scope: scope, app: app}
  end

  test "completion-messages renders the template and streams/blocks", %{conn: conn} do
    body =
      conn
      |> post(~p"/v1/completion-messages", %{
        "inputs" => %{"text" => "hello world"},
        "response_mode" => "blocking"
      })
      |> json_response(200)

    assert body["answer"] =~ "You said: Summarize: hello world"
  end

  test "completion-messages rejects chat apps", %{scope: scope} do
    {:ok, chat_app} =
      Chat.create_app(scope, %{
        "name" => "C",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, _t, raw} = Chat.create_api_token(scope, chat_app)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> post(~p"/v1/completion-messages", %{"inputs" => %{}, "response_mode" => "blocking"})

    assert json_response(conn, 400)["code"] == "invalid_app_mode"
  end

  test "files upload stores via Flux.Storage and records the row", %{conn: conn, scope: scope} do
    path = Path.join(System.tmp_dir!(), "upload-test.txt")
    File.write!(path, "file contents here")

    upload = %Plug.Upload{path: path, filename: "notes.txt", content_type: "text/plain"}

    body =
      conn
      |> post(~p"/v1/files/upload", %{"file" => upload})
      |> json_response(200)

    assert body["name"] == "notes.txt"
    assert body["size"] == 18
    assert body["extension"] == "txt"

    file = Flux.Repo.get!(Flux.Chat.UploadedFile, body["id"], skip_workspace_guard: true)
    assert file.workspace_id == Flux.Accounts.Scope.workspace_id(scope)
    assert {:ok, "file contents here"} = Flux.Storage.get(file.key)
  end

  test "webhook trigger starts a published run", %{scope: scope} do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Triggered"})

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

    {:ok, trigger} =
      Workflows.create_trigger(scope, workflow, %{
        "type" => "webhook",
        "inputs" => %{"query" => "default q"}
      })

    assert String.starts_with?(trigger.token, "wht_")

    body =
      build_conn()
      |> post(~p"/triggers/webhook/#{trigger.token}", %{"inputs" => %{"query" => "from hook"}})
      |> json_response(202)

    run_id = body["workflow_run_id"]
    assert run_id

    # Poll the run row until the echo pipeline finishes.
    run = poll_run(scope, run_id, 50)
    assert run.status == :succeeded
    assert run.outputs["answer"] =~ "You said: from hook"
  end

  test "webhook 404s on unknown token and 400s when unpublished", %{scope: scope} do
    assert build_conn()
           |> post(~p"/triggers/webhook/wht_nope", %{})
           |> json_response(404)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Unpublished"})
    {:ok, trigger} = Workflows.create_trigger(scope, workflow, %{"type" => "webhook"})

    response =
      build_conn()
      |> post(~p"/triggers/webhook/#{trigger.token}", %{})
      |> json_response(400)

    assert response["code"] == "workflow_not_published"
  end

  test "schedule worker runs due triggers", %{scope: scope} do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Scheduled"})

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

    {:ok, trigger} =
      Workflows.create_trigger(scope, workflow, %{
        "type" => "schedule",
        "interval_minutes" => 5,
        "inputs" => %{"query" => "on schedule"}
      })

    assert :ok = Flux.Workflows.ScheduleWorker.perform(%Oban.Job{})

    updated = Flux.Repo.get!(Flux.Workflows.Trigger, trigger.id, skip_workspace_guard: true)
    assert updated.last_run_at

    # Within the interval: not due again.
    [run] = Workflows.list_runs(scope, workflow.id)
    assert :ok = Flux.Workflows.ScheduleWorker.perform(%Oban.Job{})
    assert length(Workflows.list_runs(scope, workflow.id)) == 1
    assert poll_run(scope, run.id, 50).status == :succeeded
  end

  defp poll_run(scope, run_id, retries) do
    case Workflows.get_run(scope, run_id) do
      %{status: :running} when retries > 0 ->
        Process.sleep(50)
        poll_run(scope, run_id, retries - 1)

      run ->
        run
    end
  end
end
