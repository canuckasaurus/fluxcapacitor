defmodule Flux.Labeling do
  @moduledoc """
  Native data labeling: projects hold a label schema (choice / multi /
  free-text) and a queue of tasks; humans work the queue in the console
  (`/console/labeling`), relabel at will, and the labeled set exports as
  JSONL — training data for a code node, which closes the
  label → train → serve loop entirely in-app.

  Intake: rated replies from the app monitor, CSV uploads (each row's
  columns become the task `data`), or `add_task/4` from anywhere.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Labeling.{Project, Task}
  alias Flux.RBAC
  alias Flux.Repo

  @max_tasks_per_import 200

  ## Projects

  def list_projects(%Scope{} = scope) do
    Project
    |> Repo.scoped(scope)
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  def get_project(%Scope{} = scope, project_id) do
    Repo.one(Repo.scoped(where(Project, id: ^project_id), scope)) || {:error, :not_found}
  end

  def create_project(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      %Project{workspace_id: Scope.workspace_id(scope)}
      |> Project.changeset(attrs)
      |> Repo.insert()
    end
  end

  def delete_project(%Scope{} = scope, project_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Project{} = project <- get_project(scope, project_id) do
      Repo.delete(project)
    end
  end

  @doc "Whether the workspace has anywhere to send items for labeling."
  def configured?(%Scope{} = scope), do: list_projects(scope) != []

  ## Tasks

  def add_task(%Scope{} = scope, %Project{} = project, data, source \\ "manual")
      when is_map(data) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      {:ok,
       Repo.insert!(%Task{
         workspace_id: project.workspace_id,
         project_id: project.id,
         data: data,
         source: source
       })}
    end
  end

  @doc "Bulk intake from CSV rows: each row map becomes one task's data."
  def add_tasks_from_rows(%Scope{} = scope, %Project{} = project, rows) when is_list(rows) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <-
           length(rows) <= @max_tasks_per_import ||
             {:error, {:too_many_tasks, @max_tasks_per_import}} do
      tasks =
        for row <- rows do
          Repo.insert!(%Task{
            workspace_id: project.workspace_id,
            project_id: project.id,
            data: row,
            source: "csv"
          })
        end

      {:ok, tasks}
    end
  end

  @claim_seconds 600

  @doc """
  The oldest unlabeled task that isn't freshly claimed by someone else —
  and claims it for the caller, so two labelers never see the same task
  (claims expire after #{@claim_seconds}s).
  """
  def next_task(%Scope{} = scope, project_id) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@claim_seconds, :second)
    account_id = scope.account && scope.account.id

    base =
      Task
      |> Repo.scoped(scope)
      |> where([t], t.project_id == ^project_id and t.status == :unlabeled)

    query =
      if account_id do
        where(
          base,
          [t],
          is_nil(t.claimed_at) or t.claimed_at < ^cutoff or t.assigned_to_id == ^account_id
        )
      else
        where(base, [t], is_nil(t.claimed_at) or t.claimed_at < ^cutoff)
      end

    case query |> order_by([t], asc: t.inserted_at, asc: t.id) |> limit(1) |> Repo.one() do
      nil ->
        nil

      task when is_nil(account_id) ->
        task

      task ->
        task
        |> Ecto.Changeset.change(
          assigned_to_id: account_id,
          claimed_at: DateTime.utc_now(:second)
        )
        |> Repo.update!()
    end
  end

  def get_task(%Scope{} = scope, task_id) do
    Repo.one(Repo.scoped(where(Task, id: ^task_id), scope)) || {:error, :not_found}
  end

  @doc "Recently labeled tasks, newest first — the relabel surface."
  def list_labeled(%Scope{} = scope, project_id, limit \\ 25) do
    Task
    |> Repo.scoped(scope)
    |> where([t], t.project_id == ^project_id and t.status == :labeled)
    |> order_by([t], desc: t.updated_at, desc: t.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def counts(%Scope{} = scope, project_id) do
    Task
    |> Repo.scoped(scope)
    |> where([t], t.project_id == ^project_id)
    |> group_by([t], t.status)
    |> select([t], {t.status, count(t.id)})
    |> Repo.all()
    |> Map.new()
    |> then(&Map.merge(%{unlabeled: 0, labeled: 0, skipped: 0}, &1))
  end

  @doc """
  Applies a human label (works on labeled tasks too — that's relabeling).
  The label is validated against the project's schema:

    * `:choice` — `%{"choice" => option}`
    * `:multi`  — `%{"choices" => [option, ...]}`
    * `:text`   — `%{"text" => binary}`
  """
  def label_task(%Scope{} = scope, task_id, label) when is_map(label) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Task{} = task <- get_task(scope, task_id),
         %Project{} = project <- get_project(scope, task.project_id),
         :ok <- validate_label(project, label),
         {:ok, labeled} <-
           task
           |> Ecto.Changeset.change(
             status: :labeled,
             label: label,
             labeled_by_id: scope.account && scope.account.id,
             claimed_at: nil
           )
           |> Repo.update() do
      maybe_resume_run(scope, labeled)
      {:ok, labeled}
    end
  end

  # A task queued by a labeling node resumes its paused run with the
  # label as the node's outputs. Best-effort: a stopped or already
  # resumed run just leaves the label recorded.
  defp maybe_resume_run(_scope, %Task{run_id: nil}), do: :ok

  defp maybe_resume_run(scope, %Task{run_id: run_id, label: label}) do
    Flux.Workflows.resume_run(scope, run_id, label)
    :ok
  end

  def skip_task(%Scope{} = scope, task_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Task{} = task <- get_task(scope, task_id) do
      task |> Ecto.Changeset.change(status: :skipped, claimed_at: nil) |> Repo.update()
    end
  end

  @doc "Labeled-count per labeler for a project's header."
  def labeler_stats(%Scope{} = scope, project_id) do
    Task
    |> Repo.scoped(scope)
    |> where([t], t.project_id == ^project_id and t.status == :labeled)
    |> join(:left, [t], a in Flux.Accounts.Account, on: t.labeled_by_id == a.id)
    |> group_by([t, a], a.email)
    |> select([t, a], {coalesce(a.email, "unknown"), count(t.id)})
    |> order_by([t], desc: count(t.id))
    |> Repo.all()
  end

  def delete_task(%Scope{} = scope, task_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Task{} = task <- get_task(scope, task_id) do
      Repo.delete(task)
    end
  end

  defp validate_label(%Project{label_type: :choice, options: options}, %{"choice" => choice}) do
    if choice in options, do: :ok, else: {:error, :invalid_label}
  end

  defp validate_label(%Project{label_type: :multi, options: options}, %{"choices" => choices})
       when is_list(choices) and choices != [] do
    if Enum.all?(choices, &(&1 in options)), do: :ok, else: {:error, :invalid_label}
  end

  defp validate_label(%Project{label_type: :text}, %{"text" => text})
       when is_binary(text) do
    if String.trim(text) != "", do: :ok, else: {:error, :invalid_label}
  end

  defp validate_label(_project, _label), do: {:error, :invalid_label}

  ## Intake from the app monitor

  @doc "Queues one reviewed reply (or any map) as a task — the monitor's path in."
  def queue_item(%Scope{} = scope, project_id, item, source \\ "feedback") when is_map(item) do
    with %Project{} = project <- get_project(scope, project_id) do
      add_task(scope, project, item, source)
    end
  end

  @doc """
  Fans a finished batch's succeeded runs into a project: each run's
  inputs plus its primary output become one task.
  """
  def add_tasks_from_batch(%Scope{} = scope, %Project{} = project, batch_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         runs = Flux.Workflows.list_batch_runs(scope, batch_id),
         succeeded = Enum.filter(runs, &(&1.status == :succeeded)),
         true <- succeeded != [] || {:error, :no_succeeded_runs} do
      tasks =
        for run <- succeeded do
          Repo.insert!(%Task{
            workspace_id: project.workspace_id,
            project_id: project.id,
            data: Map.put(run.inputs, "output", primary_output(run.outputs)),
            source: "batch"
          })
        end

      {:ok, tasks}
    end
  end

  defp primary_output(outputs) when is_map(outputs) do
    case outputs do
      %{"answer" => answer} when is_binary(answer) -> answer
      %{"text" => text} when is_binary(text) -> text
      outputs when map_size(outputs) == 1 -> outputs |> Map.values() |> hd() |> stringify()
      outputs -> Jason.encode!(outputs)
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: Jason.encode!(value)

  @doc """
  The labeling node's path in — no scope, called from a run's host. The
  project must belong to the run's workspace; the task remembers the run
  so the label resumes it.
  """
  def queue_from_run(workspace_id, run_id, project_id, data, node_id \\ nil) do
    with {:ok, _uuid} <- cast_uuid(project_id),
         %Project{workspace_id: ^workspace_id} = project <-
           Repo.get(Project, project_id, skip_workspace_guard: true) ||
             {:error, "labeling project #{project_id} was not found in this workspace"} do
      task =
        Repo.insert!(%Task{
          workspace_id: workspace_id,
          project_id: project.id,
          run_id: run_id,
          node_id: node_id,
          data: data,
          source: "flux"
        })

      {:ok, task.id}
    else
      %Project{} -> {:error, "labeling project #{project_id} was not found in this workspace"}
      {:error, message} when is_binary(message) -> {:error, message}
      :error -> {:error, "labeling project id #{inspect(project_id)} is not a valid id"}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(to_string(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  ## Export

  @doc """
  Labeled tasks as JSONL: one `{"data": …, "label": …}` object per line
  — `pandas.read_json(lines=True)` away from a training set in a code
  node.
  """
  def export_jsonl(%Scope{} = scope, project_id) do
    with %Project{} <- get_project(scope, project_id) do
      lines =
        Task
        |> Repo.scoped(scope)
        |> where([t], t.project_id == ^project_id and t.status == :labeled)
        |> order_by([t], asc: t.inserted_at, asc: t.id)
        |> Repo.all()
        |> Enum.map_join("\n", &Jason.encode!(%{"data" => &1.data, "label" => &1.label}))

      {:ok, lines}
    end
  end
end
