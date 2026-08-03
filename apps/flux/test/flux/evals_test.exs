defmodule Flux.EvalsTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Evals
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Evals WS"})
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

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Judged Flux"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)

    %{scope: scope, workflow: workflow, workspace: workspace}
  end

  test "sets and cases: create, bulk add from rows, delete", %{scope: scope, workflow: workflow} do
    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Smoke"})
    assert [%{name: "Smoke"}] = Evals.list_sets(scope, workflow.id)

    {:ok, _} = Evals.add_case(scope, set, %{"inputs" => %{"query" => "hi"}, "expected" => "hi"})

    {:ok, cases} =
      Evals.add_cases_from_rows(scope, set, [
        %{"query" => "alpha", "expected" => "you said: alpha"},
        %{"query" => "beta", "expected" => "you said: beta"}
      ])

    assert length(cases) == 2
    all_cases = Evals.list_cases(scope, set.id)
    assert length(all_cases) == 3
    alpha = Enum.find(all_cases, &(&1.inputs == %{"query" => "alpha"}))
    assert alpha

    assert {:error, :missing_expected} =
             Evals.add_cases_from_rows(scope, set, [%{"query" => "no reference"}])

    {:ok, _} = Evals.delete_case(scope, alpha.id)
    assert length(Evals.list_cases(scope, set.id)) == 2

    {:ok, _} = Evals.delete_set(scope, set.id)
    assert Evals.list_sets(scope, workflow.id) == []
  end

  test "contains grader scores echo outputs deterministically", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Contains"})

    {:ok, _} =
      Evals.add_cases_from_rows(scope, set, [
        %{"query" => "alpha", "expected" => "you said: alpha"},
        %{"query" => "beta", "expected" => "something the echo never says"}
      ])

    {:ok, eval_run} = Evals.start_eval(scope, set, grader: "contains")
    assert eval_run.target == "draft"

    :ok = Evals.perform_eval(eval_run.id)

    finished = Evals.get_eval_run(scope, eval_run.id)
    assert finished.status == :completed
    assert finished.passed == 1
    assert finished.failed == 1
    assert finished.avg_score == 0.5

    [good, bad] = finished.results
    assert good["verdict"] == "pass"
    assert good["output"] =~ "You said: alpha"
    assert bad["verdict"] == "fail"

    # Eval executions are ordinary runs with usage attached.
    runs = Workflows.list_runs(scope, workflow.id)
    eval_runs = Enum.filter(runs, &(&1.source == :eval))
    assert length(eval_runs) == 2
    assert Enum.all?(eval_runs, &(&1.usage["output_tokens"] > 0))
  end

  test "llm_judge grades through the (injected) judge", %{scope: scope, workflow: workflow} do
    Application.put_env(:flux, :eval_judge, fn _workspace_id, [%{content: prompt}] ->
      assert prompt =~ "Reference"
      {:ok, ~s(Here you go: {"score": 0.9, "reason": "close enough"} — cheers)}
    end)

    on_exit(fn -> Application.delete_env(:flux, :eval_judge) end)

    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Judged"})

    {:ok, _} =
      Evals.add_case(scope, set, %{"inputs" => %{"query" => "x"}, "expected" => "an echo"})

    {:ok, eval_run} = Evals.start_eval(scope, set)
    :ok = Evals.perform_eval(eval_run.id)

    finished = Evals.get_eval_run(scope, eval_run.id)
    assert [result] = finished.results
    assert result["score"] == 0.9
    assert result["reason"] == "close enough"
    assert finished.passed == 1
  end

  test "a specific judge model routes through that provider", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Judged by echo"})
    {:ok, _} = Evals.add_case(scope, set, %{"inputs" => %{"query" => "x"}, "expected" => "y"})

    {:ok, eval_run} = Evals.start_eval(scope, set, judge: "echo|echo-1")
    assert eval_run.judge == "echo|echo-1"

    :ok = Evals.perform_eval(eval_run.id)

    # The echo judge answers in prose, not JSON — the grader stays honest
    # and fails the case with a parse note, proving the chosen model ran.
    finished = Evals.get_eval_run(scope, eval_run.id)
    assert [result] = finished.results
    assert result["score"] == 0.0
    assert result["reason"] =~ "could not be parsed"
    assert result["reason"] =~ "You said:"
  end

  test "evals can target a published version", %{scope: scope, workflow: workflow} do
    {:ok, _version} = Workflows.publish(scope, workflow)

    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Versioned"})

    {:ok, _} =
      Evals.add_case(scope, set, %{"inputs" => %{"query" => "v"}, "expected" => "you said: v"})

    {:ok, eval_run} = Evals.start_eval(scope, set, grader: "contains", version: 1)
    assert eval_run.target == "v1"

    :ok = Evals.perform_eval(eval_run.id)
    assert Evals.get_eval_run(scope, eval_run.id).passed == 1

    assert {:error, :version_not_found} =
             Evals.start_eval(scope, set, grader: "contains", version: 99)
  end

  test "gated sets auto-run against every published version", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Gate"})
    {:ok, set} = Evals.set_gate(scope, set.id, true) |> then(fn {:ok, s} -> {:ok, s} end)
    assert set.gate

    {:ok, _} =
      Evals.add_case(scope, set, %{"inputs" => %{"query" => "g"}, "expected" => "you said: g"})

    {:ok, version} = Workflows.publish(scope, workflow)

    assert [gated_run] = Evals.list_eval_runs(scope, set.id)
    assert gated_run.target == "v#{version.version}"

    # Ungated publishes of other sets don't fire.
    {:ok, quiet} = Evals.create_set(scope, workflow, %{"name" => "Quiet"})
    {:ok, _} = Evals.add_case(scope, quiet, %{"inputs" => %{}, "expected" => "x"})
    {:ok, _} = Workflows.publish(scope, workflow)
    assert Evals.list_eval_runs(scope, quiet.id) == []
  end

  test "start_eval refuses empty sets and unknown graders", %{scope: scope, workflow: workflow} do
    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Empty"})
    assert {:error, :no_cases} = Evals.start_eval(scope, set)
    assert {:error, :unknown_grader} = Evals.start_eval(scope, set, grader: "vibes")
  end
end
