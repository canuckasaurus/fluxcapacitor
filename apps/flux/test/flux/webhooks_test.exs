defmodule Flux.WebhooksTest do
  use Flux.DataCase, async: false
  use Oban.Testing, repo: Flux.Repo

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Webhooks
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Hooks WS"})
    scope = Accounts.scope_for(account)
    %{scope: scope, workspace: workspace}
  end

  test "create mints a server-side secret and default events", %{scope: scope} do
    {:ok, endpoint} = Webhooks.create_endpoint(scope, %{"url" => "https://hooks.example.com/x"})

    assert String.starts_with?(endpoint.secret, "whsec_")
    assert endpoint.events == ["run.succeeded", "run.failed"]
    assert endpoint.enabled

    assert [%{url: "https://hooks.example.com/x"}] = Webhooks.list_endpoints(scope)

    {:ok, _updated} = Webhooks.update_endpoint(scope, endpoint.id, %{"enabled" => false})
    {:ok, _deleted} = Webhooks.delete_endpoint(scope, endpoint.id)
    assert Webhooks.list_endpoints(scope) == []
  end

  test "rejects non-http URLs and unknown events", %{scope: scope} do
    assert {:error, changeset} =
             Webhooks.create_endpoint(scope, %{"url" => "ftp://example.com/x"})

    assert %{url: ["must be an http(s) URL"]} = errors_on(changeset)

    assert {:error, changeset} =
             Webhooks.create_endpoint(scope, %{
               "url" => "https://ok.example.com",
               "events" => ["run.succeeded", "flux.materialized"]
             })

    assert %{events: ["unknown events: flux.materialized"]} = errors_on(changeset)
  end

  test "management requires api_extension_manage", %{scope: scope} do
    member = account_fixture()
    workspace_id = Flux.Accounts.Scope.workspace_id(scope)

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace_id,
        account_id: member.id,
        role: :normal
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace_id)
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} =
             Webhooks.create_endpoint(member_scope, %{"url" => "https://x.example.com"})
  end

  test "finished runs enqueue signed deliveries to subscribed endpoints", %{scope: scope} do
    {:ok, _subscribed} =
      Webhooks.create_endpoint(scope, %{
        "url" => "https://hooks.example.com/ok",
        "events" => ["run.succeeded"]
      })

    {:ok, _other_event} =
      Webhooks.create_endpoint(scope, %{
        "url" => "https://hooks.example.com/failures-only",
        "events" => ["run.failed"]
      })

    {:ok, disabled} =
      Webhooks.create_endpoint(scope, %{"url" => "https://hooks.example.com/off"})

    {:ok, _} = Webhooks.update_endpoint(scope, disabled.id, %{"enabled" => false})

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

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Hooked"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "ping"})
    assert_receive {:run_finished, %{status: :succeeded}}, 5_000

    jobs = all_enqueued(worker: Flux.Workflows.AlertWorker)
    urls = Enum.map(jobs, & &1.args["url"])

    assert "https://hooks.example.com/ok" in urls
    refute "https://hooks.example.com/failures-only" in urls
    refute "https://hooks.example.com/off" in urls

    [job] = Enum.filter(jobs, &(&1.args["url"] == "https://hooks.example.com/ok"))
    assert job.args["payload"]["event"] == "run.succeeded"
    assert job.args["payload"]["total_tokens"] == 15
    assert String.starts_with?(job.args["secret"], "whsec_")
  end

  test "batch, eval, and feedback events fan out too", %{scope: scope} do
    {:ok, _endpoint} =
      Webhooks.create_endpoint(scope, %{
        "url" => "https://hooks.example.com/everything",
        "events" => ["*"]
      })

    # feedback.created via a rated chat reply
    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Hooked App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    conversation = Flux.Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Flux.Chat.send_message(scope, app, conversation, "rate me")
    assert_receive {:done, reply}, 5_000
    {:ok, _} = Flux.Chat.set_feedback(scope, reply.id, :like)

    events =
      all_enqueued(worker: Flux.Workflows.AlertWorker)
      |> Enum.map(& &1.args["payload"]["event"])

    assert "feedback.created" in events

    # labeling.task_labeled and labeling.project_completed on the last label
    {:ok, project} =
      Flux.Labeling.create_project(scope, %{"name" => "Hooked labels", "label_type" => "text"})

    {:ok, task} = Flux.Labeling.add_task(scope, project, %{"text" => "hi"})
    {:ok, _} = Flux.Labeling.label_task(scope, task.id, %{"text" => "hello"})

    events =
      all_enqueued(worker: Flux.Workflows.AlertWorker)
      |> Enum.map(& &1.args["payload"]["event"])

    assert "labeling.task_labeled" in events
    assert "labeling.project_completed" in events

    # deliveries keep a log row; the worker records the outcome, and a
    # retry re-enqueues the same payload
    deliveries = Webhooks.list_deliveries(scope)
    assert deliveries != []
    [delivery | _rest] = deliveries
    assert delivery.attempts == 0

    Application.put_env(:flux, :alert_req_options, plug: {Req.Test, :webhook_alerts})
    on_exit(fn -> Application.delete_env(:flux, :alert_req_options) end)
    Req.Test.stub(:webhook_alerts, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

    [job | _others] = all_enqueued(worker: Flux.Workflows.AlertWorker)
    assert :ok = perform_job(Flux.Workflows.AlertWorker, job.args)

    recorded = Enum.find(Webhooks.list_deliveries(scope), &(&1.id == job.args["delivery_id"]))
    assert recorded.status == 200
    assert recorded.attempts == 1

    {:ok, _retried} = Webhooks.retry_delivery(scope, recorded.id)

    retry_jobs =
      all_enqueued(worker: Flux.Workflows.AlertWorker)
      |> Enum.filter(&(&1.args["delivery_id"] == recorded.id))

    assert length(retry_jobs) >= 2

    # notification routing: an endpoint subscribed to one notification
    # kind gets exactly that kind forwarded
    {:ok, _routed} =
      Webhooks.create_endpoint(scope, %{
        "url" => "https://hooks.example.com/budget-only",
        "events" => ["notification.budget_warning"]
      })

    workspace_id = Flux.Accounts.Scope.workspace_id(scope)
    :ok = Flux.Notifications.notify(workspace_id, "budget_warning", "80% spent")
    :ok = Flux.Notifications.notify(workspace_id, "export_ready", "backup done")

    budget_jobs =
      all_enqueued(worker: Flux.Workflows.AlertWorker)
      |> Enum.filter(&(&1.args["url"] == "https://hooks.example.com/budget-only"))

    assert [job] = budget_jobs
    assert job.args["payload"]["event"] == "notification.budget_warning"

    # unknown event names are rejected at registration
    assert {:error, changeset} =
             Webhooks.create_endpoint(scope, %{
               "url" => "https://hooks.example.com/x",
               "events" => ["batch.completed", "nope"]
             })

    assert %{events: [message]} = errors_on(changeset)
    assert message =~ "nope"
  end
end
