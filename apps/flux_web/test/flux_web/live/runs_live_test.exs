defmodule FluxWeb.RunsLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Runs WS"})
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

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Observed Flux"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)

    %{conn: log_in_account(conn, account), scope: scope, workflow: workflow}
  end

  test "lists workspace runs with totals and filters", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "observe me"})
    assert_receive {:run_finished, %{status: :succeeded}}, 5_000

    {:ok, batch} = Workflows.start_batch(scope, workflow, [%{"query" => "batched"}])
    :ok = Workflows.perform_batch(batch.id)

    {:ok, lv, html} = live(conn, ~p"/console/runs")

    assert html =~ "Observed Flux"
    assert html =~ "2 runs"
    # Echo bills div(bytes,4) in + 12 out: "observe me" → 14, "batched" → 13.
    assert html =~ "27 tokens"

    # Filter down to batch-sourced runs only.
    html =
      lv
      |> form("#runs-filter-form", %{"workflow_id" => "", "source" => "batch", "status" => ""})
      |> render_change()

    assert html =~ "1 runs"
    assert html =~ "batch"
    refute html =~ "2 runs"
  end
end
