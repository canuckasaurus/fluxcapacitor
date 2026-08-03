defmodule FluxWeb.Perf.QualityLoadTest do
  @moduledoc """
  Load guard for the quality loop: seeds run history and labeling queues
  at scale (5k workflow runs, 5k labeling tasks), executes a real 200-row
  batch and a 100-case eval on the echo provider, and asserts the hot
  paths stay inside generous bounds. Excluded by default — run with:

      mix test --include perf apps/flux_web/test/perf
  """
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Evals
  alias Flux.Labeling
  alias Flux.Workflows

  @moduletag :perf
  @moduletag timeout: 300_000

  @runs 5_000
  @tasks 5_000
  @batch_rows 200
  @eval_cases 100

  test "runs page, batch execution, evals, and labeling stay fast at scale" do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Perf QWS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Perf Flux"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    {seed_us, :ok} = :timer.tc(fn -> seed(workspace.id, workflow.id) end)

    # Runs page: unfiltered and filtered reads over 5k+ rows.
    {runs_us, rows} = :timer.tc(fn -> Workflows.list_workspace_runs(scope, %{}, 100) end)
    assert length(rows) == 100

    {filtered_us, filtered} =
      :timer.tc(fn ->
        Workflows.list_workspace_runs(scope, %{"source" => "batch", "status" => "succeeded"}, 100)
      end)

    assert filtered != []

    # A real batch through the engine on the echo provider.
    rows = for index <- 1..@batch_rows, do: %{"query" => "perf row #{index}"}
    {:ok, batch} = Workflows.start_batch(scope, workflow, rows, name: "perf.csv")
    {batch_us, :ok} = :timer.tc(fn -> Workflows.perform_batch(batch.id) end)

    batch = Workflows.get_batch(scope, batch.id)
    assert batch.status == :completed
    assert batch.succeeded == @batch_rows

    # A real eval run (contains grader — no judge model in the loop).
    {:ok, set} = Evals.create_set(scope, workflow, %{"name" => "Perf set"})

    for index <- 1..@eval_cases do
      {:ok, _} =
        Evals.add_case(scope, set, %{
          "inputs" => %{"query" => "case #{index}"},
          "expected" => "case #{index}"
        })
    end

    {:ok, eval_run} = Evals.start_eval(scope, set, grader: "contains")
    {eval_us, :ok} = :timer.tc(fn -> Evals.perform_eval(eval_run.id) end)

    eval_run = Evals.get_eval_run(scope, eval_run.id)
    assert eval_run.status == :completed
    assert eval_run.passed == @eval_cases

    # Labeling queue reads over 5k tasks.
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Perf intent",
        "label_type" => "choice",
        "options" => ["a", "b"]
      })

    :ok = seed_tasks(workspace.id, project.id)

    {next_us, task} = :timer.tc(fn -> Labeling.next_task(scope, project.id) end)
    assert task

    {counts_us, counts} = :timer.tc(fn -> Labeling.counts(scope, project.id) end)
    assert counts.labeled + counts.unlabeled + counts.skipped == @tasks

    {stats_us, _stats} = :timer.tc(fn -> Labeling.labeler_stats(scope, project.id) end)
    {export_us, {:ok, jsonl}} = :timer.tc(fn -> Labeling.export_jsonl(scope, project.id) end)
    assert jsonl != ""

    IO.puts("""

    perf @ #{@runs} runs / #{@tasks} labeling tasks:
      seed:              #{div(seed_us, 1000)} ms
      runs page:         #{div(runs_us, 1000)} ms
      runs filtered:     #{div(filtered_us, 1000)} ms
      batch (#{@batch_rows} rows):  #{div(batch_us, 1000)} ms
      eval (#{@eval_cases} cases):   #{div(eval_us, 1000)} ms
      labeling next:     #{div(next_us, 1000)} ms
      labeling counts:   #{div(counts_us, 1000)} ms
      labeler stats:     #{div(stats_us, 1000)} ms
      jsonl export:      #{div(export_us, 1000)} ms
    """)

    # Generous CI-safe ceilings — these catch order-of-magnitude
    # regressions, not micro-noise.
    assert runs_us < 2_000_000
    assert filtered_us < 2_000_000
    assert batch_us < 60_000_000
    assert eval_us < 60_000_000
    assert next_us < 1_000_000
    assert counts_us < 1_000_000
    assert stats_us < 2_000_000
    assert export_us < 5_000_000
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

  defp seed(workspace_id, workflow_id) do
    now = DateTime.utc_now(:second)

    0..(@runs - 1)
    |> Enum.map(fn index ->
      %{
        id: UUIDv7.generate(),
        workspace_id: workspace_id,
        workflow_id: workflow_id,
        status: (rem(index, 20) == 0 && :failed) || :succeeded,
        source: Enum.at([:draft, :api, :batch, :eval], rem(index, 4)),
        inputs: %{"query" => "seed #{index}"},
        outputs: %{"answer" => "seed #{index}"},
        usage: %{"input_tokens" => 10, "output_tokens" => 20},
        elapsed_ms: 5 + rem(index, 50),
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      Flux.Repo.insert_all(Workflows.WorkflowRun, chunk, skip_workspace_guard: true)
    end)

    :ok
  end

  defp seed_tasks(workspace_id, project_id) do
    now = DateTime.utc_now(:second)

    0..(@tasks - 1)
    |> Enum.map(fn index ->
      labeled? = rem(index, 2) == 0

      %{
        id: UUIDv7.generate(),
        workspace_id: workspace_id,
        project_id: project_id,
        data: %{"text" => "task #{index}"},
        status: (labeled? && :labeled) || :unlabeled,
        label: (labeled? && %{"choice" => "a"}) || nil,
        source: "perf",
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      Flux.Repo.insert_all(Labeling.Task, chunk, skip_workspace_guard: true)
    end)

    :ok
  end
end
