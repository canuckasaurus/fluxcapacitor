defmodule Flux.Evals do
  @moduledoc """
  Evaluations: named sets of test cases run against a flux (draft or a
  published version) and graded — deterministically (`exact`, `contains`)
  or by the workspace default model as judge (`llm_judge`). Scores land
  on the eval run so versions can be compared side by side before
  publishing.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Engine
  alias Flux.Evals.{EvalCase, EvalRun, EvalSet}
  alias Flux.RBAC
  alias Flux.Repo
  alias Flux.Workflows
  alias Flux.Workflows.Workflow

  @graders ~w(exact contains llm_judge)
  @max_cases 100
  @pass_threshold 0.5

  def graders, do: @graders

  ## Sets

  def list_sets(%Scope{} = scope, workflow_id) do
    EvalSet
    |> Repo.scoped(scope)
    |> where([s], s.workflow_id == ^workflow_id)
    |> order_by([s], asc: s.inserted_at)
    |> Repo.all()
  end

  def get_set(%Scope{} = scope, set_id) do
    Repo.one(Repo.scoped(where(EvalSet, id: ^set_id), scope)) || {:error, :not_found}
  end

  def create_set(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      %EvalSet{workspace_id: Scope.workspace_id(scope), workflow_id: workflow.id}
      |> EvalSet.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Toggles a set as a publish gate (auto-runs against every new version)."
  def set_gate(%Scope{} = scope, set_id, gate?) when is_boolean(gate?) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %EvalSet{} = set <- get_set(scope, set_id) do
      set |> EvalSet.changeset(%{"gate" => gate?}) |> Repo.update()
    end
  end

  @doc """
  Publish hook: starts an eval of every gated set against the freshly
  published version. Sets with no cases are skipped quietly.
  """
  def run_gates(%Scope{} = scope, workflow_id, version) when is_integer(version) do
    for set <- list_sets(scope, workflow_id), set.gate do
      case start_eval(scope, set, version: version) do
        {:ok, eval_run} -> eval_run
        {:error, _skip} -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  def delete_set(%Scope{} = scope, set_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %EvalSet{} = set <- get_set(scope, set_id) do
      Repo.delete(set)
    end
  end

  ## Cases

  def list_cases(%Scope{} = scope, set_id) do
    EvalCase
    |> Repo.scoped(scope)
    |> where([c], c.eval_set_id == ^set_id)
    |> order_by([c], asc: c.inserted_at, asc: c.id)
    |> Repo.all()
  end

  def add_case(%Scope{} = scope, %EvalSet{} = set, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         :ok <- check_case_budget(scope, set, 1) do
      %EvalCase{workspace_id: set.workspace_id, eval_set_id: set.id}
      |> EvalCase.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Bulk-adds cases from CSV rows (maps): the `expected` column is the
  reference answer, every other column is a start input.
  """
  def add_cases_from_rows(%Scope{} = scope, %EvalSet{} = set, rows) when is_list(rows) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- Enum.all?(rows, &Map.has_key?(&1, "expected")) || {:error, :missing_expected},
         :ok <- check_case_budget(scope, set, length(rows)) do
      cases =
        for row <- rows do
          {expected, inputs} = Map.pop(row, "expected")

          Repo.insert!(%EvalCase{
            workspace_id: set.workspace_id,
            eval_set_id: set.id,
            inputs: inputs,
            expected: expected
          })
        end

      {:ok, cases}
    end
  end

  @doc "Turns a finished run into a case: its inputs, its output as the reference."
  def add_case_from_run(%Scope{} = scope, %EvalSet{} = set, run_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %{status: :succeeded} = run <- fetch_run(scope, run_id),
         :ok <- check_case_budget(scope, set, 1) do
      {:ok,
       Repo.insert!(%EvalCase{
         workspace_id: set.workspace_id,
         eval_set_id: set.id,
         inputs: run.inputs,
         expected: output_text(run.outputs)
       })}
    else
      %{} -> {:error, :not_succeeded}
      other -> other
    end
  end

  def delete_case(%Scope{} = scope, case_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %EvalCase{} = eval_case <-
           Repo.one(Repo.scoped(where(EvalCase, id: ^case_id), scope)) || {:error, :not_found} do
      Repo.delete(eval_case)
    end
  end

  defp check_case_budget(scope, set, adding) do
    existing =
      EvalCase
      |> Repo.scoped(scope)
      |> where([c], c.eval_set_id == ^set.id)
      |> Repo.aggregate(:count)

    if existing + adding <= @max_cases do
      :ok
    else
      {:error, {:too_many_cases, @max_cases}}
    end
  end

  defp fetch_run(scope, run_id) do
    Repo.one(Repo.scoped(where(Flux.Workflows.WorkflowRun, id: ^run_id), scope)) ||
      {:error, :not_found}
  end

  ## Eval runs

  def list_eval_runs(%Scope{} = scope, set_id) do
    EvalRun
    |> Repo.scoped(scope)
    |> where([r], r.eval_set_id == ^set_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(25)
    |> Repo.all()
  end

  def get_eval_run(%Scope{} = scope, eval_run_id) do
    Repo.one(Repo.scoped(where(EvalRun, id: ^eval_run_id), scope)) || {:error, :not_found}
  end

  @doc """
  Starts a graded pass over the set. `opts`:

    * `:version` — a published version number, or `nil` for the draft
    * `:grader` — `"exact"`, `"contains"`, or `"llm_judge"` (default)
    * `:judge` — `"plugin_id|model"` for the judging model; `nil` uses
      the workspace default
  """
  def start_eval(%Scope{} = scope, %EvalSet{} = set, opts \\ []) do
    grader = Keyword.get(opts, :grader, "llm_judge")
    version = Keyword.get(opts, :version)
    judge = presence(Keyword.get(opts, :judge))

    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- grader in @graders || {:error, :unknown_grader},
         cases = list_cases(scope, set.id),
         true <- cases != [] || {:error, :no_cases},
         {:ok, graph_map, target} <- resolve_target(scope, set.workflow_id, version),
         {:ok, _graph} <- Engine.build(graph_map) do
      eval_run =
        Repo.insert!(%EvalRun{
          workspace_id: set.workspace_id,
          eval_set_id: set.id,
          workflow_id: set.workflow_id,
          target: target,
          grader: grader,
          judge: judge,
          graph: graph_map,
          total: length(cases)
        })

      {:ok, _job} =
        %{"eval_run_id" => eval_run.id}
        |> Flux.Evals.EvalWorker.new()
        |> Oban.insert()

      {:ok, eval_run}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_graph, errors}}
      other -> other
    end
  end

  defp resolve_target(scope, workflow_id, nil) do
    case Repo.one(Repo.scoped(where(Workflow, id: ^workflow_id), scope)) do
      %Workflow{graph: graph} -> {:ok, graph, "draft"}
      nil -> {:error, :not_found}
    end
  end

  defp resolve_target(scope, workflow_id, version) when is_integer(version) do
    case Workflows.get_version(scope, workflow_id, version) do
      %{graph: graph} -> {:ok, graph, "v#{version}"}
      {:error, :not_found} -> {:error, :version_not_found}
    end
  end

  def topic(workflow_id), do: "evals:#{workflow_id}"

  def subscribe(workflow_id), do: Phoenix.PubSub.subscribe(Flux.PubSub, topic(workflow_id))

  @doc false
  # Executed inside Flux.Evals.EvalWorker.
  def perform_eval(eval_run_id) do
    eval_run = Repo.get(EvalRun, eval_run_id, skip_workspace_guard: true)

    with %EvalRun{status: :running} <- eval_run,
         {:ok, graph} <- Engine.build(eval_run.graph) do
      scope = %Scope{workspace: %Flux.Accounts.Workspace{id: eval_run.workspace_id}}
      cases = list_cases(scope, eval_run.eval_set_id)

      results =
        for eval_case <- cases do
          {output, run_error} = execute_case(eval_run, graph, eval_case)
          {score, reason} = grade(eval_run, eval_case, output, run_error)

          %{
            "case_id" => eval_case.id,
            "inputs" => eval_case.inputs,
            "expected" => eval_case.expected,
            "output" => output,
            "error" => run_error,
            "score" => score,
            "verdict" => (score >= @pass_threshold && "pass") || "fail",
            "reason" => reason
          }
        end

      passed = Enum.count(results, &(&1["verdict"] == "pass"))

      avg =
        case results do
          [] -> nil
          results -> Float.round(Enum.sum(Enum.map(results, & &1["score"])) / length(results), 4)
        end

      eval_run
      |> Ecto.Changeset.change(
        status: :completed,
        results: results,
        passed: passed,
        failed: length(results) - passed,
        avg_score: avg
      )
      |> Repo.update!()

      Phoenix.PubSub.broadcast(
        Flux.PubSub,
        topic(eval_run.workflow_id),
        {:eval_updated, eval_run.id}
      )

      previous_avg = previous_avg_score(eval_run)

      Flux.Webhooks.dispatch(eval_run.workspace_id, "eval.completed", %{
        "eval_run_id" => eval_run.id,
        "eval_set_id" => eval_run.eval_set_id,
        "workflow_id" => eval_run.workflow_id,
        "target" => eval_run.target,
        "grader" => eval_run.grader,
        "passed" => passed,
        "failed" => length(results) - passed,
        "avg_score" => avg,
        "previous_avg_score" => previous_avg,
        "regressed" => is_number(avg) and is_number(previous_avg) and avg < previous_avg
      })
    end

    :ok
  end

  # The most recent completed run of the same set before this one — the
  # regression baseline.
  defp previous_avg_score(eval_run) do
    EvalRun
    |> where(
      [r],
      r.eval_set_id == ^eval_run.eval_set_id and r.id != ^eval_run.id and
        r.status == :completed and r.workspace_id == ^eval_run.workspace_id
    )
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      %EvalRun{avg_score: avg} -> avg
      nil -> nil
    end
  end

  # Runs one case as a real workflow run (source :eval) so token usage
  # and traces land in the ordinary run history.
  defp execute_case(eval_run, graph, eval_case) do
    run =
      Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: eval_run.workspace_id,
        workflow_id: eval_run.workflow_id,
        status: :running,
        source: :eval,
        inputs: eval_case.inputs
      })

    case Workflows.execute_for_eval(run, graph, eval_case.inputs) do
      {:ok, %{status: :succeeded} = finished} -> {output_text(finished.outputs), nil}
      {:ok, %{error: error}} -> {nil, error || "run did not succeed"}
    end
  end

  defp grade(_eval_run, _case, nil, run_error), do: {0.0, "run failed: #{run_error}"}

  defp grade(%EvalRun{grader: "exact"}, eval_case, output, _error) do
    if normalize(output) == normalize(eval_case.expected) do
      {1.0, "exact match"}
    else
      {0.0, "output differs from the expected answer"}
    end
  end

  defp grade(%EvalRun{grader: "contains"}, eval_case, output, _error) do
    if String.contains?(normalize(output), normalize(eval_case.expected)) do
      {1.0, "expected text found in output"}
    else
      {0.0, "expected text not found in output"}
    end
  end

  defp grade(%EvalRun{grader: "llm_judge"} = eval_run, eval_case, output, _error) do
    prompt = """
    You are grading an AI workflow's output against a reference.

    Inputs: #{Jason.encode!(eval_case.inputs)}
    Reference (expected answer or criteria): #{eval_case.expected}
    Actual output: #{output}

    Score how well the actual output satisfies the reference on a 0.0–1.0
    scale (1.0 = fully satisfies). Reply with ONLY a JSON object:
    {"score": <number>, "reason": "<one sentence>"}
    """

    case judge_reply(eval_run, [%{role: :user, content: prompt}]) do
      {:ok, reply} -> parse_judge_reply(reply)
      {:error, :no_default_model} -> {0.0, "no workspace default model to judge with"}
      {:error, reason} -> {0.0, "judge errored: #{inspect(reason)}"}
    end
  end

  # Test injection wins; otherwise a per-eval judge ("plugin|model"),
  # falling back to the workspace default model.
  defp judge_reply(eval_run, messages) do
    case Application.get_env(:flux, :eval_judge) do
      nil ->
        case parse_judge_choice(eval_run.judge) do
          {plugin_id, model} ->
            Workflows.invoke_model_for_workspace(
              eval_run.workspace_id,
              plugin_id,
              model,
              messages
            )

          nil ->
            Workflows.invoke_default_llm_for_workspace(eval_run.workspace_id, messages)
        end

      fun when is_function(fun, 2) ->
        fun.(eval_run.workspace_id, messages)
    end
  end

  defp parse_judge_choice(judge) do
    case String.split(to_string(judge || ""), "|", parts: 2) do
      [plugin_id, model] when plugin_id != "" and model != "" -> {plugin_id, model}
      _default -> nil
    end
  end

  defp presence(nil), do: nil
  defp presence(text) when is_binary(text), do: with("" <- String.trim(text), do: nil)

  defp parse_judge_reply(reply) do
    with {:ok, start} <- find(reply, "{"),
         {:ok, stop} <- rfind(reply, "}"),
         {:ok, %{"score" => score} = decoded} <-
           Jason.decode(binary_part(reply, start, stop - start + 1)),
         true <- is_number(score) do
      {score |> max(0.0) |> min(1.0) |> Kernel.*(1.0), decoded["reason"] || "judged"}
    else
      _unparseable -> {0.0, "the judge reply could not be parsed: #{String.slice(reply, 0, 120)}"}
    end
  end

  defp find(text, needle) do
    case :binary.match(text, needle) do
      {index, _length} -> {:ok, index}
      :nomatch -> :error
    end
  end

  defp rfind(text, needle) do
    case :binary.matches(text, needle) do
      [] -> :error
      matches -> {:ok, matches |> List.last() |> elem(0)}
    end
  end

  defp output_text(outputs) when is_map(outputs) do
    case outputs do
      %{"answer" => answer} when is_binary(answer) -> answer
      %{"text" => text} when is_binary(text) -> text
      outputs when map_size(outputs) == 1 -> outputs |> Map.values() |> hd() |> stringify()
      outputs -> Jason.encode!(outputs)
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: Jason.encode!(value)

  defp normalize(text), do: text |> to_string() |> String.trim() |> String.downcase()
end
