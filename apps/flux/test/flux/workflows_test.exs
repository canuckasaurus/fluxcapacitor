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

    # Wait until the run is inside the (slow) LLM node before stopping.
    assert_receive {:engine_event, {:node_started, %{node_id: "llm_1"}}}, 2_000

    assert {:ok, stopped} = Workflows.stop_run(scope, run.id)
    assert stopped.status == :stopped
    assert_receive {:run_finished, %{status: :stopped}}, 2_000
  end
end
