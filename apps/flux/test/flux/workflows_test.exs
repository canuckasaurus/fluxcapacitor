defmodule Flux.WorkflowsTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  # Runs execute against Flux.FakeRuntime (see test_helper.exs); flux_web
  # suites exercise the real runtime end-to-end.
  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Flux WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Test Flux"})
    %{scope: scope, workflow: workflow, workspace: workspace}
  end

  defp echo_graph do
    %{
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
  end

  test "new workflows carry the starter graph", %{workflow: workflow} do
    node_types = Enum.map(workflow.graph["nodes"], & &1["type"])
    assert node_types == ["start", "llm", "answer"]
  end

  test "draft run streams engine events and persists the trace", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    {:ok, run} = Workflows.start_run(scope, workflow, %{"query" => "hello flux"})
    assert run.status == :running

    assert_receive {:engine_event, {:node_started, %{node_id: "start"}}}, 2_000
    assert_receive {:engine_event, {:node_chunk, %{node_id: "llm_1"}}}, 2_000
    assert_receive {:run_finished, finished}, 5_000

    assert finished.status == :succeeded
    assert finished.outputs["answer"] =~ "You said: hello flux"
    assert length(finished.node_executions) == 3
    assert finished.elapsed_ms >= 0
    assert [%{status: :succeeded}] = Workflows.list_runs(scope, workflow.id)
  end

  test "runs record aggregated token usage with an estimated cost", %{
    scope: scope,
    workflow: workflow
  } do
    Application.put_env(:flux, :model_pricing, %{"echo-1" => {1.0, 2.0}})
    on_exit(fn -> Application.delete_env(:flux, :model_pricing) end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "count me"})
    assert_receive {:run_finished, finished}, 5_000

    # FakeRuntime bills every LLM call at 3 in / 12 out.
    assert finished.usage["input_tokens"] == 3
    assert finished.usage["output_tokens"] == 12

    assert finished.usage["by_model"] == %{
             "echo-1" => %{"input_tokens" => 3, "output_tokens" => 12}
           }

    assert_in_delta finished.usage["estimated_cost_usd"], (3 * 1.0 + 12 * 2.0) / 1_000_000, 1.0e-9

    [persisted] = Workflows.list_runs(scope, workflow.id)
    assert persisted.usage["input_tokens"] == 3
  end

  test "run fails cleanly when a node errors", %{scope: scope, workflow: workflow} do
    broken =
      update_in(echo_graph(), ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node -> put_in(node, ["config", "model"], "")
          node -> node
        end)
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, broken)
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "x"})

    assert_receive {:run_finished, finished}, 5_000
    assert finished.status == :failed
    assert finished.error =~ "provider and model"
  end

  test "batches run every row and tally results", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    rows = [%{"query" => "row one"}, %{"query" => "row two"}, %{"query" => "row three"}]
    {:ok, batch} = Workflows.start_batch(scope, workflow, rows, name: "smoke.csv")

    assert batch.total == 3
    assert batch.status == :running

    # Oban is in manual testing mode; run the batch inline.
    :ok = Workflows.perform_batch(batch.id)

    finished = Workflows.get_batch(scope, batch.id)
    assert finished.status == :completed
    assert finished.succeeded == 3
    assert finished.failed == 0

    runs = Workflows.list_batch_runs(scope, batch.id)
    assert length(runs) == 3
    assert Enum.all?(runs, &(&1.status == :succeeded and &1.source == :batch))
    assert Enum.at(runs, 0).outputs["answer"] =~ "You said: row one"
    assert Enum.at(runs, 2).outputs["answer"] =~ "You said: row three"
  end

  test "batches can target a published version", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _version} = Workflows.publish(scope, workflow)

    # Break the draft afterwards — the batch must still run the snapshot.
    {:ok, workflow} = Workflows.update_draft(scope, workflow, %{"nodes" => [], "edges" => []})

    {:ok, batch} =
      Workflows.start_batch(scope, workflow, [%{"query" => "versioned"}],
        name: "v.csv",
        version: 1
      )

    assert batch.target == "v1"
    :ok = Workflows.perform_batch(batch.id)

    assert Workflows.get_batch(scope, batch.id).succeeded == 1

    assert {:error, :version_not_found} =
             Workflows.start_batch(scope, workflow, [%{"query" => "x"}], version: 9)
  end

  test "batch schedules re-run a saved row set on their cron minute", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    {:ok, batch} =
      Workflows.start_batch(scope, workflow, [%{"query" => "nightly"}], name: "nightly.csv")

    :ok = Workflows.perform_batch(batch.id)

    # Bad cron refused; a valid one saves the batch's rows.
    assert {:error, changeset} = Workflows.schedule_batch(scope, batch.id, "not cron")
    assert %{cron: [message]} = errors_on(changeset)
    assert message =~ "cron"

    {:ok, schedule} = Workflows.schedule_batch(scope, batch.id, "* * * * *")
    assert schedule.rows == [%{"query" => "nightly"}]
    assert schedule.target == "draft"
    assert [_schedule] = Workflows.list_batch_schedules(scope, workflow.id)

    now = DateTime.utc_now(:second)
    assert [new_batch] = Workflows.run_scheduled_batches(now)
    assert new_batch.name == "nightly.csv"
    assert new_batch.total == 1

    # Same minute: suppressed. Disabled: never fires.
    assert Workflows.run_scheduled_batches(now) == []
    {:ok, _} = Workflows.toggle_batch_schedule(scope, schedule.id)
    assert Workflows.run_scheduled_batches(DateTime.add(now, 60, :second)) == []

    {:ok, _} = Workflows.delete_batch_schedule(scope, schedule.id)
    assert Workflows.list_batch_schedules(scope, workflow.id) == []
  end

  test "flux costs roll up per workflow and export as CSV", %{scope: scope, workflow: workflow} do
    Application.put_env(:flux, :model_pricing, %{"echo-1" => {1.0, 2.0}})
    on_exit(fn -> Application.delete_env(:flux, :model_pricing) end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "bill me"})
    assert_receive {:run_finished, %{status: :succeeded}}, 5_000

    assert [row] = Flux.Usage.flux_costs(scope)
    assert row.name == "Test Flux"
    assert row.runs == 1
    assert row.tokens == 15
    assert row.cost > 0

    csv = Flux.Usage.flux_costs_csv(scope)
    assert csv =~ "flux,runs,tokens,estimated_cost_usd"
    assert csv =~ "Test Flux,1,15,"
  end

  test "workspace run filters narrow by date", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "dated"})
    assert_receive {:run_finished, _finished}, 5_000

    today = Date.utc_today()
    assert [_row] = Workflows.list_workspace_runs(scope, %{from: today, to: today})
    assert [] = Workflows.list_workspace_runs(scope, %{to: Date.add(today, -2)})
  end

  test "the LLM cache returns repeats for free within the TTL", %{
    scope: scope,
    workflow: workflow
  } do
    Flux.LLMCache.purge()
    {:ok, _} = Accounts.set_llm_cache_minutes(scope, 10)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "cache me"})
    assert_receive {:run_finished, first}, 5_000
    assert first.usage["output_tokens"] == 12

    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "cache me"})
    assert_receive {:run_finished, second}, 5_000

    # Cache hit: same answer, zero billed tokens.
    assert second.outputs["answer"] == first.outputs["answer"]
    assert second.usage["input_tokens"] == 0
    assert second.usage["output_tokens"] == 0

    # Different inputs miss the cache.
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "fresh"})
    assert_receive {:run_finished, third}, 5_000
    assert third.usage["output_tokens"] == 12

    Flux.LLMCache.purge()
    {:ok, _} = Accounts.set_llm_cache_minutes(scope, 0)
  end

  test "the monthly token budget warns at 80% and refuses past the cap", %{
    scope: scope,
    workflow: workflow,
    workspace: workspace
  } do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    # One echo run costs 15 tokens; an 18-token budget is 83% spent after it.
    {:ok, _} = Accounts.set_token_budget(scope, 18)

    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "spend"})
    assert_receive {:run_finished, _first}, 5_000
    assert Flux.Usage.month_tokens(workspace.id) == 15

    # Under the cap but over 80%: allowed, with a warning notification.
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "warn"})
    assert_receive {:run_finished, _second}, 5_000

    assert Enum.any?(
             Flux.Notifications.list(scope),
             &(&1.kind == "budget_warning")
           )

    # Now 30 of 18: refused.
    assert {:error, :budget_exhausted} =
             Workflows.start_run(scope, workflow, %{"query" => "denied"})

    {:ok, _} = Accounts.set_token_budget(scope, nil)
  end

  test "the concurrency cap refuses interactive runs while others execute", %{
    scope: scope,
    workflow: workflow,
    workspace: workspace
  } do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _} = Accounts.set_max_concurrent_runs(scope, 1)

    # Pin one run in :running state deterministically.
    Repo.insert!(%Flux.Workflows.WorkflowRun{
      workspace_id: workspace.id,
      workflow_id: workflow.id,
      status: :running
    })

    assert {:error, :concurrency_limit} =
             Workflows.start_run(scope, workflow, %{"query" => "capped"})

    # Batch-sourced runs stay exempt (their workers serialize already).
    assert {:ok, _run} =
             Workflows.start_run(scope, workflow, %{"query" => "batch row"}, source: :batch)

    assert_receive {:run_finished, _finished}, 5_000

    {:ok, _} = Accounts.set_max_concurrent_runs(scope, nil)
  end

  test "workspace templates save, list, and delete", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    {:ok, template} = Workflows.save_as_template(scope, workflow)
    assert template.name == workflow.name
    assert template.graph == workflow.graph

    assert [%{name: _name}] = Workflows.list_workspace_templates(scope)

    {:ok, _} = Workflows.delete_workspace_template(scope, template.id)
    assert Workflows.list_workspace_templates(scope) == []
  end

  test "A/B split routes live traffic between published versions", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, _v1} = Workflows.publish(scope, workflow)
    {:ok, _v2} = Workflows.publish(scope, workflow)

    workflow = Workflows.get_workflow(scope, workflow.id)

    # No split: always the latest.
    assert Workflows.serving_version(scope, workflow).version == 2

    # 100% to B: always version 1.
    {:ok, workflow} = Workflows.set_ab_split(scope, workflow, 1, 100)
    assert workflow.ab_split == 100

    for _try <- 1..10 do
      assert Workflows.serving_version(scope, workflow).version == 1
    end

    # Unknown version B refused; split 0 clears.
    assert {:error, :version_not_found} = Workflows.set_ab_split(scope, workflow, 99, 50)
    {:ok, workflow} = Workflows.set_ab_split(scope, workflow, nil, 0)
    assert workflow.ab_version_b == nil
    assert Workflows.serving_version(scope, workflow).version == 2

    # Stats group runs by the version that served them.
    {:ok, _run} =
      Workflows.start_run(scope, workflow, %{"query" => "arm"},
        source: :api,
        graph: echo_graph(),
        version: 1
      )

    assert_receive {:run_finished, _finished}, 5_000
    assert [%{version: 1, runs: 1, success_rate: 1.0}] = Workflows.ab_stats(scope, workflow.id)
  end

  test "diff_graphs reports node and edge changes, ignoring positions" do
    old_graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "start", "title" => "Start", "config" => %{}},
        %{
          "id" => "llm_1",
          "type" => "llm",
          "title" => "LLM",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{"prompt" => "old"}
        },
        %{"id" => "gone", "type" => "template", "title" => "Gone", "config" => %{}}
      ],
      "edges" => [
        %{"source" => "start", "source_handle" => "default", "target" => "llm_1"},
        %{"source" => "llm_1", "source_handle" => "default", "target" => "gone"}
      ]
    }

    new_graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "start", "title" => "Start", "config" => %{}},
        %{
          "id" => "llm_1",
          "type" => "llm",
          "title" => "LLM",
          "position" => %{"x" => 500, "y" => 500},
          "config" => %{"prompt" => "new"}
        },
        %{"id" => "fresh", "type" => "answer", "title" => "Fresh", "config" => %{}}
      ],
      "edges" => [
        %{"source" => "start", "source_handle" => "default", "target" => "llm_1"},
        %{"source" => "llm_1", "source_handle" => "default", "target" => "fresh"}
      ]
    }

    diff = Workflows.diff_graphs(old_graph, new_graph)

    assert [%{id: "fresh", type: "answer"}] = diff.added
    assert [%{id: "gone"}] = diff.removed
    # Position moved AND prompt changed — only the prompt counts.
    assert [%{id: "llm_1", fields: ["prompt"]}] = diff.changed
    assert diff.edges_added == ["llm_1 –default→ fresh"]
    assert diff.edges_removed == ["llm_1 –default→ gone"]
  end

  test "start_batch rejects empty and oversized uploads", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    assert {:error, :empty} = Workflows.start_batch(scope, workflow, [])

    too_many = List.duplicate(%{"query" => "x"}, 201)
    assert {:error, {:too_many_rows, 200}} = Workflows.start_batch(scope, workflow, too_many)
  end

  test "start_run rejects an invalid graph", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, %{"nodes" => [], "edges" => []})
    assert {:error, {:invalid_graph, errors}} = Workflows.start_run(scope, workflow, %{})
    assert Enum.any?(errors, &(&1 =~ "start node"))
  end

  test "publish snapshots versions and validates the graph", %{scope: scope, workflow: workflow} do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    assert {:ok, version_1} = Workflows.publish(scope, workflow)
    assert version_1.version == 1

    assert {:ok, version_2} = Workflows.publish(scope, workflow)
    assert version_2.version == 2
    assert Workflows.latest_version(scope, workflow.id).version == 2

    {:ok, broken} = Workflows.update_draft(scope, workflow, %{"nodes" => [], "edges" => []})
    assert {:error, {:invalid_graph, _errors}} = Workflows.publish(scope, broken)
  end

  test "workflows are workspace-scoped", %{workflow: workflow} do
    other = account_fixture()
    {:ok, _} = Accounts.create_workspace(other, %{name: "Other"})
    other_scope = Accounts.scope_for(other)

    assert Workflows.list_workflows(other_scope) == []
    assert {:error, :not_found} = Workflows.get_workflow(other_scope, workflow.id)
    assert {:error, :not_found} = Workflows.delete_workflow(other_scope, workflow)
  end

  test "mutations require the matching permissions", %{workflow: workflow} do
    member = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workflow.workspace_id,
        account_id: member.id,
        role: :normal
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workflow.workspace_id)
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} = Workflows.create_workflow(member_scope, %{"name" => "No"})
    assert {:error, :unauthorized} = Workflows.update_draft(member_scope, workflow, echo_graph())
    assert {:error, :unauthorized} = Workflows.publish(member_scope, workflow)
    assert {:error, :unauthorized} = Workflows.delete_workflow(member_scope, workflow)
    assert {:error, :unauthorized} = Workflows.create_api_token(member_scope, workflow)
  end

  test "api tokens roundtrip with the flux- prefix", %{scope: scope, workflow: workflow} do
    {:ok, token, raw} = Workflows.create_api_token(scope, workflow)
    assert String.starts_with?(raw, "flux-")
    assert token.workflow_id == workflow.id

    assert {:ok, resolved, _token} = Workflows.fetch_workflow_by_token(raw)
    assert resolved.id == workflow.id

    assert {:error, :invalid_token} = Workflows.fetch_workflow_by_token("flux-bogus")
    assert {:error, :invalid_token} = Workflows.fetch_workflow_by_token("app-not-a-flux")
  end

  test "stop_run marks a running row stopped", %{scope: scope, workflow: workflow} do
    slow =
      update_in(echo_graph(), ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node ->
            put_in(node, ["config", "provider_plugin_id"], "slow_echo")

          node ->
            node
        end)
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, slow)
    {:ok, run} = Workflows.start_run(scope, workflow, %{"query" => "hi"})

    # Wait until the run is inside the (slow) LLM node before stopping —
    # past the credentials DB read that follows node_started, so the kill
    # lands during the provider sleep, not mid-query in the sandbox.
    assert_receive {:engine_event, {:node_started, %{node_id: "llm_1"}}}, 2_000
    Process.sleep(200)

    assert {:ok, stopped} = Workflows.stop_run(scope, run.id)
    assert stopped.status == :stopped
    assert_receive {:run_finished, %{status: :stopped}}, 2_000
  end

  test "failed runs enqueue an alert and the worker delivers it", %{scope: scope} do
    Application.put_env(:flux, :alert_req_options, plug: {Req.Test, Flux.AlertStub})
    on_exit(fn -> Application.delete_env(:flux, :alert_req_options) end)

    parent = self()

    Req.Test.stub(Flux.AlertStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [signature] = Plug.Conn.get_req_header(conn, "x-flux-signature")
      send(parent, {:alert_body, Jason.decode!(body), body, signature})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    {:ok, _workspace} = Flux.Accounts.set_alert_url(scope, "https://hooks.example.com/alerts")

    # A run that fails: LLM node with no provider configured.
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Alerting Flux"})

    graph =
      update_in(workflow.graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node -> put_in(node, ["config", "provider_plugin_id"], "")
          node -> node
        end)
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "boom"})
    assert_receive {:run_finished, %{status: :failed}}, 2_000

    assert %{success: 1} = Oban.drain_queue(queue: :default)
    assert_receive {:alert_body, body, raw_body, signature}, 1_000
    assert body["event"] == "run.failed"
    assert body["workflow_name"] == "Alerting Flux"
    assert body["error"] =~ "provider"

    # The delivery is signed over the exact body bytes with the minted secret.
    secret = Flux.Accounts.alert_secret(scope)
    assert String.starts_with?(secret, "whsec_")

    expected =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw_body), case: :lower)

    assert signature == expected
  end

  test "cleanup worker prunes old runs and messages per retention window", %{scope: scope} do
    {:ok, _workspace} = Flux.Accounts.set_retention_days(scope, 7)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Old Flux"})

    old = DateTime.add(DateTime.utc_now(:second), -10, :day)

    stale_run =
      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workflow.workspace_id,
        workflow_id: workflow.id,
        status: :succeeded,
        inserted_at: old,
        updated_at: old
      })

    fresh_run =
      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workflow.workspace_id,
        workflow_id: workflow.id,
        status: :succeeded
      })

    # Paused runs survive regardless of age (they hold resume snapshots).
    paused_run =
      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workflow.workspace_id,
        workflow_id: workflow.id,
        status: :paused,
        inserted_at: old,
        updated_at: old
      })

    # Run-output files age out with the runs; fresh ones and chat
    # uploads survive.
    workspace_id = workflow.workspace_id
    :ok = Flux.Storage.put("run_outputs/#{workspace_id}/stale.docx", "old bytes")
    :ok = Flux.Storage.put("run_outputs/#{workspace_id}/fresh.docx", "new bytes")
    :ok = Flux.Storage.put("uploads/#{workspace_id}/chat.txt", "chat bytes")

    stale_file =
      Flux.Repo.insert!(%Flux.Chat.UploadedFile{
        workspace_id: workspace_id,
        name: "stale.docx",
        key: "run_outputs/#{workspace_id}/stale.docx",
        size: 9,
        download_token: "file_stale_test",
        inserted_at: old,
        updated_at: old
      })

    fresh_file =
      Flux.Repo.insert!(%Flux.Chat.UploadedFile{
        workspace_id: workspace_id,
        name: "fresh.docx",
        key: "run_outputs/#{workspace_id}/fresh.docx",
        size: 9,
        download_token: "file_fresh_test"
      })

    chat_file =
      Flux.Repo.insert!(%Flux.Chat.UploadedFile{
        workspace_id: workspace_id,
        name: "chat.txt",
        key: "uploads/#{workspace_id}/chat.txt",
        size: 10,
        inserted_at: old,
        updated_at: old
      })

    assert :ok = Flux.Workflows.CleanupWorker.perform(%Oban.Job{})

    refute Flux.Repo.get(Flux.Workflows.WorkflowRun, stale_run.id, skip_workspace_guard: true)
    assert Flux.Repo.get(Flux.Workflows.WorkflowRun, fresh_run.id, skip_workspace_guard: true)
    assert Flux.Repo.get(Flux.Workflows.WorkflowRun, paused_run.id, skip_workspace_guard: true)

    refute Flux.Repo.get(Flux.Chat.UploadedFile, stale_file.id, skip_workspace_guard: true)
    assert {:error, _gone} = Flux.Storage.get(stale_file.key)
    assert Flux.Repo.get(Flux.Chat.UploadedFile, fresh_file.id, skip_workspace_guard: true)
    assert {:ok, _kept} = Flux.Storage.get(fresh_file.key)
    assert Flux.Repo.get(Flux.Chat.UploadedFile, chat_file.id, skip_workspace_guard: true)
    assert {:ok, _kept} = Flux.Storage.get(chat_file.key)
  end

  test "human_input pauses a run and resume_run completes it", %{scope: scope} do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "HITL Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [
              %{"name" => "query", "label" => "Query", "type" => "text", "required" => true}
            ]
          }
        },
        %{
          "id" => "ask",
          "type" => "human_input",
          "title" => "Approve",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{"prompt" => "Approve {{start.query}}?", "options" => ["yes", "no"]}
        },
        %{
          "id" => "t",
          "type" => "template",
          "title" => "Result",
          "position" => %{"x" => 600, "y" => 0},
          "config" => %{"template" => "approved: {{ask.output}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "ask"},
        %{"id" => "e2", "source" => "ask", "source_handle" => "default", "target" => "t"}
      ]
    }

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, run} = Workflows.start_run(scope, workflow, %{"query" => "the release"})

    assert_receive {:run_finished, %{status: :paused} = paused}, 2_000
    assert paused.id == run.id
    assert paused.snapshot["prompt"]["prompt"] == "Approve the release?"

    assert {:ok, _resumed} = Workflows.resume_run(scope, run.id, "yes")
    assert_receive {:run_finished, %{status: :succeeded} = finished}, 2_000
    assert finished.outputs["output"] == "approved: yes"

    # The trace keeps both phases: the paused node and the resumed tail.
    statuses = Enum.map(finished.node_executions, & &1["status"])
    assert "paused" in statuses

    assert {:error, :not_paused} = Workflows.resume_run(scope, run.id, "again")
  end
end
