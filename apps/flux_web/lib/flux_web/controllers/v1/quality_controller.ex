defmodule FluxWeb.V1.QualityController do
  @moduledoc """
  The quality loop over the service API: start batches and evals with a
  `flux-…` token, and drive labeling (list projects, push tasks, pull
  the next unlabeled one, submit labels, export) with any valid token —
  so CI and data pipelines can run the loop without the console.
  """
  use FluxWeb, :controller

  alias Flux.Evals
  alias Flux.Labeling
  alias Flux.Workflows

  ## Batches (flux-… tokens)

  def batch_create(conn, params) do
    with {:ok, workflow} <- require_workflow(conn),
         rows when is_list(rows) and rows != [] <- params["rows"] || :missing_rows,
         true <- Enum.all?(rows, &is_map/1) || :invalid_rows,
         {:ok, batch} <-
           Workflows.start_batch(conn.assigns.service_scope, workflow, rows,
             name: to_string(params["name"] || "api"),
             version: parse_version(params["version"])
           ) do
      conn
      |> put_status(202)
      |> json(%{
        batch_id: batch.id,
        status: batch.status,
        target: batch.target,
        total: batch.total
      })
    else
      :missing_rows -> error(conn, 400, "invalid_param", "rows must be a non-empty array")
      :invalid_rows -> error(conn, 400, "invalid_param", "every row must be an object")
      {:error, {:too_many_rows, max}} -> error(conn, 400, "invalid_param", "at most #{max} rows")
      {:error, :version_not_found} -> error(conn, 404, "not_found", "unknown version")
      {:error, {:invalid_graph, [first | _]}} -> error(conn, 422, "invalid_graph", first)
      {:error, :no_workflow_token} -> workflow_token_error(conn)
      _other -> error(conn, 400, "invalid_param", "could not start the batch")
    end
  end

  def batch_show(conn, %{"id" => id} = params) do
    with {:ok, workflow} <- require_workflow(conn),
         %Workflows.WorkflowBatch{workflow_id: workflow_id} = batch
         when workflow_id == workflow.id <-
           Workflows.get_batch(conn.assigns.service_scope, id) do
      payload = %{
        batch_id: batch.id,
        status: batch.status,
        target: batch.target,
        total: batch.total,
        succeeded: batch.succeeded,
        failed: batch.failed
      }

      payload =
        if params["include_results"] == "true" do
          results =
            for run <- Workflows.list_batch_runs(conn.assigns.service_scope, batch.id) do
              %{inputs: run.inputs, status: run.status, outputs: run.outputs, error: run.error}
            end

          Map.put(payload, :results, results)
        else
          payload
        end

      json(conn, payload)
    else
      {:error, :no_workflow_token} -> workflow_token_error(conn)
      _not_found -> error(conn, 404, "not_found", "batch not found")
    end
  end

  ## Evals (flux-… tokens)

  def eval_sets(conn, _params) do
    with {:ok, workflow} <- require_workflow(conn) do
      sets =
        for set <- Evals.list_sets(conn.assigns.service_scope, workflow.id) do
          %{id: set.id, name: set.name, gate: set.gate}
        end

      json(conn, %{data: sets})
    else
      {:error, :no_workflow_token} -> workflow_token_error(conn)
    end
  end

  def eval_run_create(conn, %{"id" => set_id} = params) do
    scope = conn.assigns.service_scope

    with {:ok, workflow} <- require_workflow(conn),
         %Evals.EvalSet{workflow_id: workflow_id} = set when workflow_id == workflow.id <-
           Evals.get_set(scope, set_id),
         {:ok, eval_run} <-
           Evals.start_eval(scope, set,
             grader: to_string(params["grader"] || "llm_judge"),
             version: parse_version(params["version"]),
             judge: params["judge"]
           ) do
      conn
      |> put_status(202)
      |> json(%{eval_run_id: eval_run.id, status: eval_run.status, target: eval_run.target})
    else
      {:error, :no_workflow_token} -> workflow_token_error(conn)
      {:error, :no_cases} -> error(conn, 422, "no_cases", "the set has no cases")
      {:error, :unknown_grader} -> error(conn, 400, "invalid_param", "unknown grader")
      {:error, :version_not_found} -> error(conn, 404, "not_found", "unknown version")
      _not_found -> error(conn, 404, "not_found", "eval set not found")
    end
  end

  def eval_run_show(conn, %{"id" => id}) do
    with {:ok, workflow} <- require_workflow(conn),
         %Evals.EvalRun{workflow_id: workflow_id} = eval_run when workflow_id == workflow.id <-
           Evals.get_eval_run(conn.assigns.service_scope, id) do
      json(conn, %{
        eval_run_id: eval_run.id,
        status: eval_run.status,
        target: eval_run.target,
        grader: eval_run.grader,
        total: eval_run.total,
        passed: eval_run.passed,
        failed: eval_run.failed,
        avg_score: eval_run.avg_score,
        results: eval_run.results
      })
    else
      {:error, :no_workflow_token} -> workflow_token_error(conn)
      _not_found -> error(conn, 404, "not_found", "eval run not found")
    end
  end

  ## Labeling (any valid token)

  def labeling_projects(conn, _params) do
    projects =
      for project <- Labeling.list_projects(conn.assigns.service_scope) do
        counts = Labeling.counts(conn.assigns.service_scope, project.id)

        %{
          id: project.id,
          name: project.name,
          label_type: project.label_type,
          options: project.options,
          counts: counts
        }
      end

    json(conn, %{data: projects})
  end

  def labeling_tasks_create(conn, %{"id" => project_id} = params) do
    scope = conn.assigns.service_scope

    with %Labeling.Project{} = project <- Labeling.get_project(scope, project_id),
         items when is_list(items) and items != [] <- params["items"] || :missing_items,
         true <- length(items) <= 100 || :too_many do
      tasks =
        for item <- items do
          data = if is_map(item), do: item, else: %{"text" => to_string(item)}
          {:ok, task} = Labeling.add_task(scope, project, data, "api")
          task.id
        end

      conn |> put_status(201) |> json(%{task_ids: tasks, count: length(tasks)})
    else
      :missing_items -> error(conn, 400, "invalid_param", "items must be a non-empty array")
      :too_many -> error(conn, 400, "invalid_param", "at most 100 items per call")
      _not_found -> error(conn, 404, "not_found", "labeling project not found")
    end
  end

  def labeling_next(conn, %{"id" => project_id}) do
    scope = conn.assigns.service_scope

    with %Labeling.Project{} = project <- Labeling.get_project(scope, project_id) do
      case Labeling.next_task(scope, project.id) do
        nil ->
          json(conn, %{task: nil})

        task ->
          json(conn, %{
            task: %{
              id: task.id,
              data: task.data,
              label_type: project.label_type,
              options: project.options
            }
          })
      end
    else
      _not_found -> error(conn, 404, "not_found", "labeling project not found")
    end
  end

  def labeling_label(conn, %{"id" => task_id} = params) do
    case Labeling.label_task(conn.assigns.service_scope, task_id, params["label"] || %{}) do
      {:ok, task} ->
        json(conn, %{task_id: task.id, status: task.status, label: task.label})

      {:error, :invalid_label} ->
        error(conn, 422, "invalid_label", "the label does not match the project's schema")

      _not_found ->
        error(conn, 404, "not_found", "task not found")
    end
  end

  def labeling_export(conn, %{"id" => project_id}) do
    case Labeling.export_jsonl(conn.assigns.service_scope, project_id) do
      {:ok, jsonl} ->
        conn
        |> put_resp_content_type("application/jsonl")
        |> send_resp(200, jsonl <> "\n")

      _not_found ->
        error(conn, 404, "not_found", "labeling project not found")
    end
  end

  ## Helpers

  defp require_workflow(conn) do
    case conn.assigns[:service_workflow] do
      nil -> {:error, :no_workflow_token}
      workflow -> {:ok, workflow}
    end
  end

  defp workflow_token_error(conn) do
    error(conn, 403, "wrong_token", "this endpoint needs a flux-… workflow token")
  end

  defp parse_version(nil), do: nil
  defp parse_version(version) when is_integer(version), do: version

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {n, ""} -> n
      _invalid -> nil
    end
  end

  defp error(conn, status, code, message) do
    conn |> put_status(status) |> json(%{code: code, message: message})
  end
end
