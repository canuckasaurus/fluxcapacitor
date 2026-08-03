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

  @stream_timeout 300_000

  @doc false
  # SSE progress for a batch: `batch_progress` events as rows land, a
  # final `batch_completed`. Symmetric with /v1/workflows/run streaming.
  def batch_events(conn, %{"id" => id}) do
    with {:ok, workflow} <- require_workflow(conn),
         %Workflows.WorkflowBatch{workflow_id: workflow_id} = batch
         when workflow_id == workflow.id <-
           Workflows.get_batch(conn.assigns.service_scope, id) do
      Workflows.subscribe_batches(workflow.id)

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      {_status, conn} = sse(conn, batch_progress_payload(batch))

      if batch.status == :completed do
        conn
      else
        batch_stream_loop(conn, batch.id)
      end
    else
      {:error, :no_workflow_token} -> workflow_token_error(conn)
      _not_found -> error(conn, 404, "not_found", "batch not found")
    end
  end

  defp batch_stream_loop(conn, batch_id) do
    receive do
      {:batch_updated, ^batch_id} ->
        batch = Flux.Repo.get(Workflows.WorkflowBatch, batch_id, skip_workspace_guard: true)
        {_status, conn} = sse(conn, batch_progress_payload(batch))

        if batch.status == :completed, do: conn, else: batch_stream_loop(conn, batch_id)

      {:batch_updated, _other} ->
        batch_stream_loop(conn, batch_id)
    after
      @stream_timeout ->
        {_status, conn} = sse(conn, %{event: "error", code: "timeout"})
        conn
    end
  end

  defp batch_progress_payload(batch) do
    %{
      event: (batch.status == :completed && "batch_completed") || "batch_progress",
      batch_id: batch.id,
      status: batch.status,
      total: batch.total,
      succeeded: batch.succeeded,
      failed: batch.failed
    }
  end

  @doc false
  # SSE progress for an eval run: one `eval_progress` per re-score, a
  # final `eval_completed` with the summary.
  def eval_events(conn, %{"id" => id}) do
    with {:ok, workflow} <- require_workflow(conn),
         %Evals.EvalRun{workflow_id: workflow_id} = eval_run when workflow_id == workflow.id <-
           Evals.get_eval_run(conn.assigns.service_scope, id) do
      Evals.subscribe(workflow.id)

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      {_status, conn} = sse(conn, eval_progress_payload(eval_run))

      if eval_run.status == :completed do
        conn
      else
        eval_stream_loop(conn, eval_run.id)
      end
    else
      {:error, :no_workflow_token} -> workflow_token_error(conn)
      _not_found -> error(conn, 404, "not_found", "eval run not found")
    end
  end

  defp eval_stream_loop(conn, eval_run_id) do
    receive do
      {:eval_updated, ^eval_run_id} ->
        eval_run = Flux.Repo.get(Evals.EvalRun, eval_run_id, skip_workspace_guard: true)
        {_status, conn} = sse(conn, eval_progress_payload(eval_run))

        if eval_run.status == :completed, do: conn, else: eval_stream_loop(conn, eval_run_id)

      {:eval_updated, _other} ->
        eval_stream_loop(conn, eval_run_id)
    after
      @stream_timeout ->
        {_status, conn} = sse(conn, %{event: "error", code: "timeout"})
        conn
    end
  end

  defp eval_progress_payload(eval_run) do
    %{
      event: (eval_run.status == :completed && "eval_completed") || "eval_progress",
      eval_run_id: eval_run.id,
      status: eval_run.status,
      total: eval_run.total,
      passed: eval_run.passed,
      failed: eval_run.failed,
      avg_score: eval_run.avg_score
    }
  end

  defp sse(conn, payload), do: chunk(conn, "data: " <> Jason.encode!(payload) <> "\n\n")

  ## Evals (flux-… tokens)

  def eval_sets(conn, _params) do
    with {:ok, workflow} <- require_workflow(conn) do
      sets =
        for set <- Evals.list_sets(conn.assigns.service_scope, workflow.id) do
          %{id: set.id, name: set.name, gate: set.gate, schedule: set.schedule}
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

  ## Model registry (any valid token)

  def models(conn, _params) do
    models =
      for artifact <- Flux.Registry.list(conn.assigns.service_scope) do
        %{
          id: artifact.id,
          name: artifact.name,
          version: artifact.version,
          file_id: artifact.file_id,
          file_name: artifact.file.name,
          metrics: artifact.metrics
        }
      end

    json(conn, %{data: models})
  end

  def model_register(conn, params) do
    case Flux.Registry.register(
           conn.assigns.service_scope,
           params["name"],
           to_string(params["file_id"] || ""),
           metrics: (is_map(params["metrics"]) && params["metrics"]) || %{}
         ) do
      {:ok, artifact} ->
        conn
        |> put_status(201)
        |> json(%{id: artifact.id, name: artifact.name, version: artifact.version})

      {:error, :blank_name} ->
        error(conn, 400, "invalid_param", "name is required")

      {:error, :file_not_found} ->
        error(conn, 404, "not_found", "file not found in this workspace")

      _error ->
        error(conn, 400, "invalid_param", "could not register the model")
    end
  end

  ## Notifications (any valid token)

  def notifications(conn, params) do
    limit = min(max(parse_int(params["limit"], 30), 1), 100)

    notifications =
      for notification <- Flux.Notifications.list(conn.assigns.service_scope, limit) do
        %{
          id: notification.id,
          kind: notification.kind,
          title: notification.title,
          path: notification.path,
          read: notification.read_at != nil,
          created_at: DateTime.to_unix(notification.inserted_at)
        }
      end

    json(conn, %{data: notifications})
  end

  ## Retrieval evals (any valid token)

  def retrieval_cases(conn, %{"id" => dataset_id}) do
    scope = conn.assigns.service_scope

    with %{} = _dataset <- rag().get_dataset(scope, dataset_id) do
      cases =
        for retrieval_case <- rag().list_retrieval_cases(scope, dataset_id) do
          %{
            id: retrieval_case.id,
            question: retrieval_case.question,
            expected: retrieval_case.expected
          }
        end

      json(conn, %{data: cases})
    else
      _not_found -> error(conn, 404, "not_found", "dataset not found")
    end
  end

  def retrieval_case_create(conn, %{"id" => dataset_id} = params) do
    scope = conn.assigns.service_scope

    with %{} = dataset <- rag().get_dataset(scope, dataset_id),
         {:ok, retrieval_case} <-
           rag().add_retrieval_case(scope, dataset, %{
             "question" => params["question"],
             "expected" => params["expected"]
           }) do
      conn |> put_status(201) |> json(%{id: retrieval_case.id})
    else
      {:error, %Ecto.Changeset{}} ->
        error(conn, 400, "invalid_param", "question and expected are both required")

      _not_found ->
        error(conn, 404, "not_found", "dataset not found")
    end
  end

  def retrieval_eval(conn, %{"id" => dataset_id}) do
    scope = conn.assigns.service_scope

    with %{} = _dataset <- rag().get_dataset(scope, dataset_id) do
      summary = rag().evaluate_retrieval(scope, dataset_id)

      json(conn, %{
        total: summary.total,
        hits: summary.hits,
        hit_rate: summary.hit_rate,
        mrr: summary.mrr,
        results:
          for result <- summary.results do
            %{
              case_id: result.case_id,
              question: result.question,
              expected: result.expected,
              rank: result.rank
            }
          end
      })
    else
      _not_found -> error(conn, 404, "not_found", "dataset not found")
    end
  end

  defp rag, do: Application.get_env(:flux, :rag_module, Flux.RAG)

  defp parse_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _invalid -> default
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
    conn |> put_status(status) |> json(%{code: code, message: message, status: status})
  end
end
