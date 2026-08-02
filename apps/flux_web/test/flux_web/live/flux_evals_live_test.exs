defmodule FluxWeb.FluxEvalsLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Evals
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Evals WS"})
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

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Evaluated"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)

    %{conn: log_in_account(conn, account), scope: scope, workflow: workflow}
  end

  test "sets, cases, and a graded pass end to end", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    {:ok, lv, html} = live(conn, ~p"/console/fluxes/#{workflow.id}/evals")
    assert html =~ "Evaluations"

    lv |> form("#create-set-form", %{"name" => "Regression"}) |> render_submit()

    html =
      lv
      |> form("#add-case-form", %{
        "inputs" => %{"query" => "alpha"},
        "expected" => "you said: alpha"
      })
      |> render_submit()

    assert html =~ "Case added."
    assert html =~ "you said: alpha"

    html =
      lv
      |> form("#run-eval-form", %{"target" => "draft", "grader" => "contains"})
      |> render_submit()

    assert html =~ "Evaluation started."

    [set] = Evals.list_sets(scope, workflow.id)
    [eval_run] = Evals.list_eval_runs(scope, set.id)

    # Oban is manual under test; grade inline, PubSub refreshes the page.
    :ok = Evals.perform_eval(eval_run.id)

    html = render(lv)
    assert html =~ "100.0"

    html = lv |> element("#eval-#{eval_run.id} button", "Details") |> render_click()
    assert html =~ "Per-case results"
    assert html =~ "You said: alpha"
  end
end
