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
  alias Flux.Labeling.{Project, Task, Vote}
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
        base
        |> where(
          [t],
          is_nil(t.claimed_at) or t.claimed_at < ^cutoff or t.assigned_to_id == ^account_id
        )
        # In consensus projects a labeler never sees a task twice.
        |> join(:left, [t], v in Vote, on: v.task_id == t.id and v.account_id == ^account_id)
        |> where([t, v], is_nil(v.id))
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
         :ok <- validate_label(project, label) do
      if project.required_labels > 1 and task.status == :unlabeled do
        record_vote(scope, project, task, label)
      else
        apply_label(scope, project, task, label)
      end
    end
  end

  defp apply_label(scope, project, task, label) do
    with {:ok, labeled} <-
           task
           |> Ecto.Changeset.change(
             status: :labeled,
             label: label,
             labeled_by_id: scope.account && scope.account.id,
             claimed_at: nil
           )
           |> Repo.update() do
      maybe_resume_run(scope, labeled)
      notify_labeled(project, labeled)
      {:ok, labeled}
    end
  end

  # One vote per account per task; a repeat vote replaces the first.
  # Once the project's quorum is in, the majority label (earliest vote
  # breaks ties) becomes the task's label.
  defp record_vote(scope, project, task, label) do
    account_id = scope.account && scope.account.id

    if account_id do
      Repo.delete_all(
        from(v in Vote, where: v.task_id == ^task.id and v.account_id == ^account_id),
        skip_workspace_guard: true
      )
    end

    Repo.insert!(%Vote{
      workspace_id: task.workspace_id,
      task_id: task.id,
      account_id: account_id,
      label: label
    })

    votes =
      Vote
      |> where([v], v.task_id == ^task.id)
      |> order_by([v], asc: v.inserted_at, asc: v.id)
      |> Repo.all(skip_workspace_guard: true)

    if length(votes) >= project.required_labels do
      apply_label(scope, project, task, consensus_label(votes))
    else
      # Release the claim so the next labeler can weigh in.
      task |> Ecto.Changeset.change(claimed_at: nil, assigned_to_id: nil) |> Repo.update()
    end
  end

  defp consensus_label(votes) do
    votes
    |> Enum.group_by(& &1.label)
    |> Enum.max_by(fn {_label, group} ->
      earliest = group |> Enum.map(&DateTime.to_unix(&1.inserted_at)) |> Enum.min()
      {length(group), -earliest}
    end)
    |> elem(0)
  end

  defp notify_labeled(project, task) do
    Flux.Webhooks.dispatch(task.workspace_id, "labeling.task_labeled", %{
      "project_id" => project.id,
      "project_name" => project.name,
      "task_id" => task.id,
      "label" => task.label,
      "source" => task.source
    })

    remaining =
      Task
      |> where([t], t.project_id == ^project.id and t.status == :unlabeled)
      |> Repo.aggregate(:count, skip_workspace_guard: true)

    if remaining == 0 do
      Flux.Webhooks.dispatch(task.workspace_id, "labeling.project_completed", %{
        "project_id" => project.id,
        "project_name" => project.name
      })
    end

    :ok
  end

  @doc """
  Inter-labeler agreement over a project's consensus-labeled tasks:
  the average fraction of votes matching the final label, plus the
  unanimity rate. `nil` when no task has more than one vote.
  """
  def agreement_stats(%Scope{} = scope, project_id) do
    tasks =
      Task
      |> Repo.scoped(scope)
      |> where([t], t.project_id == ^project_id and t.status == :labeled)
      |> Repo.all()

    votes_by_task =
      Vote
      |> where([v], v.task_id in ^Enum.map(tasks, & &1.id))
      |> Repo.all(skip_workspace_guard: true)
      |> Enum.group_by(& &1.task_id)

    fractions =
      for task <- tasks, votes = votes_by_task[task.id] || [], length(votes) > 1 do
        Enum.count(votes, &(&1.label == task.label)) / length(votes)
      end

    case fractions do
      [] ->
        nil

      fractions ->
        %{
          tasks: length(fractions),
          avg_agreement: Enum.sum(fractions) / length(fractions),
          unanimous: Enum.count(fractions, &(&1 == 1.0))
        }
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

  @doc """
  Promotes a labeled task to a **gold standard** (honeypot): its current
  label becomes the reference answer, the task re-enters the unlabeled
  queue, and every future label or vote on it scores the labeler against
  the gold answer. Prior votes are cleared for a fresh round.
  """
  def promote_to_gold(%Scope{} = scope, task_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Task{status: :labeled, label: label} = task when is_map(label) <-
           get_task(scope, task_id) do
      Repo.delete_all(from(v in Vote, where: v.task_id == ^task.id), skip_workspace_guard: true)

      task
      |> Ecto.Changeset.change(
        gold_label: label,
        status: :unlabeled,
        label: nil,
        labeled_by_id: nil,
        assigned_to_id: nil,
        claimed_at: nil
      )
      |> Repo.update()
    else
      %Task{} -> {:error, :not_labeled}
      other -> other
    end
  end

  @doc """
  Per-labeler accuracy against the project's gold tasks: consensus
  projects score each vote, single-label projects score the applied
  label. Returns `[{email, correct, total}]`, best first; `[]` when the
  project has no scored gold answers yet.
  """
  def labeler_accuracy(%Scope{} = scope, %Project{} = project) do
    gold_tasks =
      Task
      |> Repo.scoped(scope)
      |> where([t], t.project_id == ^project.id and not is_nil(t.gold_label))
      |> Repo.all()

    scores =
      if project.required_labels > 1 do
        votes =
          Vote
          |> where([v], v.task_id in ^Enum.map(gold_tasks, & &1.id))
          |> Repo.all(skip_workspace_guard: true)

        gold_by_task = Map.new(gold_tasks, &{&1.id, &1.gold_label})

        for vote <- votes, gold = gold_by_task[vote.task_id] do
          {vote.account_id, vote.label == gold}
        end
      else
        for task <- gold_tasks, task.status == :labeled, is_map(task.label) do
          {task.labeled_by_id, task.label == task.gold_label}
        end
      end

    emails = account_emails(Enum.map(scores, &elem(&1, 0)))

    scores
    |> Enum.group_by(fn {account_id, _correct?} -> account_id end)
    |> Enum.map(fn {account_id, group} ->
      correct = Enum.count(group, fn {_id, correct?} -> correct? end)
      {Map.get(emails, account_id, "unknown"), correct, length(group)}
    end)
    |> Enum.sort_by(fn {_email, correct, total} -> -correct / max(total, 1) end)
  end

  defp account_emails(account_ids) do
    Flux.Accounts.Account
    |> where([a], a.id in ^Enum.reject(account_ids, &is_nil/1))
    |> select([a], {a.id, a.email})
    |> Repo.all()
    |> Map.new()
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
