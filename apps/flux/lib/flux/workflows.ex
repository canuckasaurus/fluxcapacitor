defmodule Flux.Workflows do
  @moduledoc """
  Fluxes: workflow CRUD, draft editing, publishing, and supervised runs.

  A run executes `Flux.Engine` in a supervised task registered by run id;
  engine events broadcast on `"workflow_run:{id}"` as `{:engine_event, event}`
  followed by a final `{:run_finished, run}` — LiveViews and SSE controllers
  are plain PubSub subscribers, mirroring `Flux.Chat`'s generation pipeline.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Chat.ApiToken
  alias Flux.Engine
  alias Flux.Engine.Host
  alias Flux.Providers
  alias Flux.RBAC
  alias Flux.Repo
  alias Flux.Workflows.{Workflow, WorkflowBatch, WorkflowRun, WorkflowVersion}

  defp runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  @default_graph %{
    "nodes" => [
      %{
        "id" => "start",
        "type" => "start",
        "title" => "Start",
        "position" => %{"x" => 60, "y" => 220},
        "config" => %{
          "variables" => [
            %{"name" => "query", "label" => "Query", "type" => "text", "required" => true}
          ]
        }
      },
      %{
        "id" => "llm_1",
        "type" => "llm",
        "title" => "LLM",
        "position" => %{"x" => 380, "y" => 200},
        "config" => %{
          "provider_plugin_id" => "",
          "model" => "",
          "system_prompt" => "",
          "prompt" => "{{start.query}}"
        }
      },
      %{
        "id" => "answer_1",
        "type" => "answer",
        "title" => "Answer",
        "position" => %{"x" => 700, "y" => 220},
        "config" => %{"answer" => "{{llm_1.text}}"}
      }
    ],
    "edges" => [
      %{
        "id" => "edge_start_llm_1",
        "source" => "start",
        "source_handle" => "default",
        "target" => "llm_1"
      },
      %{
        "id" => "edge_llm_1_answer_1",
        "source" => "llm_1",
        "source_handle" => "default",
        "target" => "answer_1"
      }
    ]
  }

  def default_graph, do: @default_graph

  ## Workflows

  def list_workflows(%Scope{} = scope) do
    Workflow
    |> Repo.scoped(scope)
    |> where([w], is_nil(w.deleted_at))
    |> order_by([w], desc: w.updated_at)
    |> Repo.all()
  end

  def get_workflow(%Scope{} = scope, id) do
    Workflow
    |> where(id: ^id)
    |> where([w], is_nil(w.deleted_at))
    |> Repo.scoped(scope)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      workflow -> workflow
    end
  end

  @doc "Latest published version per workflow in one query (fluxes listing)."
  def latest_versions(%Scope{} = scope) do
    from(v in WorkflowVersion,
      distinct: v.workflow_id,
      order_by: [asc: v.workflow_id, desc: v.version]
    )
    |> Repo.scoped(scope)
    |> Repo.all()
    |> Map.new(&{&1.workflow_id, &1})
  end

  @doc "Trashed fluxes, newest deletion first."
  def list_trashed_workflows(%Scope{} = scope) do
    Workflow
    |> Repo.scoped(scope)
    |> where([w], not is_nil(w.deleted_at))
    |> order_by([w], desc: w.deleted_at)
    |> Repo.all()
  end

  def create_workflow(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management) do
      %Workflow{
        workspace_id: Scope.workspace_id(scope),
        created_by_id: Scope.account_id(scope),
        graph: @default_graph
      }
      |> Workflow.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Imports a portable DSL YAML export as a new flux. Returns
  `{:ok, workflow, warnings}` — warnings list dropped/approximated pieces.
  """
  def import_dsl(%Scope{} = scope, yaml) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         {:ok, parsed} <- Flux.Workflows.DSL.parse(yaml) do
      %Workflow{
        workspace_id: Scope.workspace_id(scope),
        created_by_id: Scope.account_id(scope),
        graph: parsed.graph
      }
      |> Workflow.changeset(%{"name" => parsed.name, "description" => parsed.description})
      |> Repo.insert()
      |> case do
        {:ok, workflow} -> {:ok, workflow, parsed.warnings}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def update_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         :ok <- owned(scope, workflow) do
      workflow |> Workflow.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Persists the draft graph. Drafts may be structurally incomplete (the
  editor saves every mutation); `run`/`publish` are the strict gates.
  """
  def update_draft(%Scope{} = scope, %Workflow{} = workflow, graph) when is_map(graph) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         :ok <- owned(scope, workflow) do
      workflow
      |> Ecto.Changeset.change(graph: graph)
      |> Repo.update()
    end
  end

  @doc "Soft delete: the flux moves to the trash (30-day purge, restorable)."
  def delete_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         :ok <- owned(scope, workflow),
         {:ok, trashed} <-
           workflow
           |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second), site_enabled: false)
           |> Repo.update() do
      Flux.Audit.record(scope, "workflow.trash", resource: workflow)
      {:ok, trashed}
    end
  end

  def restore_workflow(%Scope{} = scope, workflow_id) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         %Workflow{} = workflow <-
           Repo.one(Repo.scoped(where(Workflow, id: ^workflow_id), scope)) ||
             {:error, :not_found},
         {:ok, restored} <-
           workflow |> Ecto.Changeset.change(deleted_at: nil) |> Repo.update() do
      Flux.Audit.record(scope, "workflow.restore", resource: workflow)
      {:ok, restored}
    end
  end

  @doc "Hard delete from the trash — gone for good."
  def purge_workflow(%Scope{} = scope, workflow_id) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         %Workflow{deleted_at: %DateTime{}} = workflow <-
           Repo.one(Repo.scoped(where(Workflow, id: ^workflow_id), scope)) ||
             {:error, :not_found},
         {:ok, deleted} <- Repo.delete(workflow) do
      Flux.Audit.record(scope, "workflow.purge", resource: workflow)
      {:ok, deleted}
    else
      %Workflow{} -> {:error, :not_trashed}
      error -> error
    end
  end

  @doc "Copies a flux's draft graph and description into a new '(copy)' flux."
  def duplicate_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    with {:ok, copy} <-
           create_workflow(scope, %{
             "name" => workflow.name <> " (copy)",
             "description" => workflow.description
           }) do
      update_draft(scope, copy, workflow.graph || %{})
    end
  end

  ## Workspace templates ("save as template" → the gallery)

  @doc "Saves a flux's current draft graph as a workspace template."
  def save_as_template(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         :ok <- owned(scope, workflow) do
      %Flux.Workflows.WorkspaceTemplate{
        workspace_id: workflow.workspace_id,
        graph: workflow.graph
      }
      |> Flux.Workflows.WorkspaceTemplate.changeset(%{
        "name" => workflow.name,
        "description" => workflow.description
      })
      |> Repo.insert()
    end
  end

  def list_workspace_templates(%Scope{} = scope) do
    Flux.Workflows.WorkspaceTemplate
    |> Repo.scoped(scope)
    |> order_by([t], asc: t.name)
    |> Repo.all()
  end

  def get_workspace_template(%Scope{} = scope, template_id) do
    Repo.one(Repo.scoped(where(Flux.Workflows.WorkspaceTemplate, id: ^template_id), scope)) ||
      {:error, :not_found}
  end

  def delete_workspace_template(%Scope{} = scope, template_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Flux.Workflows.WorkspaceTemplate{} = template <-
           get_workspace_template(scope, template_id) do
      Repo.delete(template)
    end
  end

  ## Publishing

  def publish(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- RBAC.authorize(scope, :app_release_and_version),
         :ok <- owned(scope, workflow),
         {:ok, _graph} <- Engine.build(workflow.graph) do
      version = %WorkflowVersion{
        workspace_id: workflow.workspace_id,
        workflow_id: workflow.id,
        published_by_id: Scope.account_id(scope),
        version: next_version(scope, workflow),
        graph: workflow.graph
      }

      inserted = Repo.insert!(version)

      Flux.Audit.record(scope, "workflow.publish",
        resource: workflow,
        metadata: %{"version" => inserted.version}
      )

      # Gated eval sets score every new version automatically.
      Flux.Evals.run_gates(scope, workflow.id, inserted.version)

      {:ok, inserted}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_graph, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Structural diff between two graphs: nodes added/removed/changed (by
  id; position moves don't count as changes, changed lists the touched
  config keys) and edges added/removed (by source/handle/target).
  """
  def diff_graphs(old_graph, new_graph) do
    old_nodes = Map.new(List.wrap(old_graph["nodes"]), &{&1["id"], &1})
    new_nodes = Map.new(List.wrap(new_graph["nodes"]), &{&1["id"], &1})

    added =
      for {id, node} <- new_nodes, not Map.has_key?(old_nodes, id) do
        %{id: id, type: node["type"], title: node["title"]}
      end

    removed =
      for {id, node} <- old_nodes, not Map.has_key?(new_nodes, id) do
        %{id: id, type: node["type"], title: node["title"]}
      end

    changed =
      for {id, node} <- new_nodes,
          old = old_nodes[id],
          old != nil,
          fields = changed_fields(old, node),
          fields != [] do
        %{id: id, type: node["type"], title: node["title"], fields: fields}
      end

    old_edges = edge_set(old_graph)
    new_edges = edge_set(new_graph)

    %{
      added: Enum.sort_by(added, & &1.id),
      removed: Enum.sort_by(removed, & &1.id),
      changed: Enum.sort_by(changed, & &1.id),
      edges_added: MapSet.difference(new_edges, old_edges) |> MapSet.to_list() |> Enum.sort(),
      edges_removed: MapSet.difference(old_edges, new_edges) |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp changed_fields(old, new) do
    meta =
      for key <- ["type", "title"], old[key] != new[key], do: key

    old_config = old["config"] || %{}
    new_config = new["config"] || %{}

    config_keys =
      (Map.keys(old_config) ++ Map.keys(new_config))
      |> Enum.uniq()
      |> Enum.filter(fn key -> old_config[key] != new_config[key] end)

    meta ++ Enum.sort(config_keys)
  end

  defp edge_set(graph) do
    for edge <- List.wrap(graph["edges"]), into: MapSet.new() do
      "#{edge["source"]} –#{edge["source_handle"] || "default"}→ #{edge["target"]}"
    end
  end

  def list_versions(%Scope{} = scope, workflow_id) do
    WorkflowVersion
    |> Repo.scoped(scope)
    |> where([v], v.workflow_id == ^workflow_id)
    |> order_by([v], desc: v.version)
    |> Repo.all()
  end

  def get_version(%Scope{} = scope, workflow_id, version) do
    Repo.one(
      WorkflowVersion
      |> Repo.scoped(scope)
      |> where([v], v.workflow_id == ^workflow_id and v.version == ^version)
    ) || {:error, :not_found}
  end

  @doc """
  The version a *live* run should execute: the latest published version,
  or — when an A/B split is configured — version B for `ab_split`% of
  traffic. Chatflow turns, public sites, triggers, and `/v1` runs all
  resolve through here; the run records which version served it, so the
  arms compare on the runs data.
  """
  def serving_version(%Scope{} = scope, %Workflow{} = workflow) do
    latest = latest_version(scope, workflow.id)

    with %WorkflowVersion{} <- latest,
         split when is_integer(split) and split > 0 <- workflow.ab_split,
         version_b when is_integer(version_b) <- workflow.ab_version_b,
         true <- :rand.uniform(100) <= split,
         %WorkflowVersion{} = arm_b <- get_version(scope, workflow.id, version_b) do
      arm_b
    else
      _no_split_or_arm_a -> latest
    end
  end

  @doc "Configures (split 1–100 to version B) or clears (split 0) the A/B test."
  def set_ab_split(%Scope{} = scope, %Workflow{} = workflow, version_b, split)
      when is_integer(split) and split in 0..100 do
    with :ok <- RBAC.authorize(scope, :app_release_and_version),
         :ok <- owned(scope, workflow),
         true <-
           split == 0 or match?(%WorkflowVersion{}, get_version(scope, workflow.id, version_b)) ||
             {:error, :version_not_found} do
      workflow
      |> Ecto.Changeset.change(
        ab_version_b: (split > 0 && version_b) || nil,
        ab_split: split
      )
      |> Repo.update()
    end
  end

  @doc "Per-version run stats for the A/B view: count, success rate, avg tokens."
  def ab_stats(%Scope{} = scope, workflow_id) do
    WorkflowRun
    |> Repo.scoped(scope)
    |> where([r], r.workflow_id == ^workflow_id and not is_nil(r.version))
    |> select([r], %{version: r.version, status: r.status, usage: r.usage})
    |> Repo.all()
    |> Enum.group_by(& &1.version)
    |> Enum.map(fn {version, runs} ->
      succeeded = Enum.count(runs, &(&1.status == :succeeded))

      tokens =
        Enum.sum(
          for run <- runs,
              do: (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0)
        )

      count = length(runs)

      %{
        version: version,
        runs: count,
        success_rate: Float.round(succeeded / count, 4),
        avg_tokens: (count > 0 && div(tokens, count)) || 0
      }
    end)
    |> Enum.sort_by(& &1.version, :desc)
  end

  def latest_version(%Scope{} = scope, workflow_id) do
    WorkflowVersion
    |> Repo.scoped(scope)
    |> where([v], v.workflow_id == ^workflow_id)
    |> order_by([v], desc: v.version)
    |> limit(1)
    |> Repo.one()
  end

  defp next_version(scope, workflow) do
    case latest_version(scope, workflow.id) do
      nil -> 1
      %WorkflowVersion{version: version} -> version + 1
    end
  end

  ## Runs

  @doc "Per-flux 7-day run health (`%{workflow_id => %{runs, succeeded, tokens}}`)."
  def flux_health(%Scope{} = scope, days \\ 7) do
    since = DateTime.add(DateTime.utc_now(:second), -days, :day)

    WorkflowRun
    |> Repo.scoped(scope)
    |> where([r], r.inserted_at >= ^since)
    |> group_by([r], r.workflow_id)
    |> select([r], {
      r.workflow_id,
      %{
        runs: count(r.id),
        succeeded: fragment("count(*) filter (where ? = 'succeeded')", r.status),
        tokens:
          fragment(
            "coalesce(sum(coalesce((? ->> 'input_tokens')::bigint, 0) + coalesce((? ->> 'output_tokens')::bigint, 0)), 0)",
            r.usage,
            r.usage
          )
      }
    })
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Validates the graph, inserts a `:running` row, subscribes the caller to
  the run topic, and executes in a supervised task. `opts`:

    * `:source` — `:draft` (default) or `:api`
    * `:graph` — graph map to execute (defaults to the workflow's draft)
    * `:version` — version number recorded on the run
  """
  def start_run(%Scope{} = scope, %Workflow{} = workflow, inputs, opts \\ []) do
    graph_map = Keyword.get(opts, :graph, workflow.graph)

    with :ok <- check_token_budget(workflow.workspace_id),
         :ok <- check_flux_budget(workflow),
         :ok <- check_concurrency(workflow.workspace_id, Keyword.get(opts, :source, :draft)),
         :ok <-
           Flux.Guardrails.check_input(
             workflow.workspace_id,
             Jason.encode!(inputs),
             "run input (#{workflow.name})"
           ) do
      do_start_run(scope, workflow, graph_map, inputs, opts)
    end
  end

  # An optional per-flux monthly cap alongside the workspace budget:
  # past it new runs refuse with :flux_budget_exhausted; at 80% one
  # notification per month fires.
  defp check_flux_budget(%Workflow{monthly_token_budget: nil}), do: :ok

  defp check_flux_budget(%Workflow{monthly_token_budget: budget} = workflow)
       when is_integer(budget) do
    spent = Flux.Usage.month_tokens_for_workflow(workflow.id)
    month = Calendar.strftime(Date.utc_today(), "%Y-%m")

    cond do
      spent >= budget ->
        {:error, :flux_budget_exhausted}

      spent >= budget * 0.8 and workflow.budget_warned_month != month ->
        Flux.Notifications.notify(
          workflow.workspace_id,
          "budget_warning",
          "#{workflow.name}: flux budget 80% spent (#{spent} of #{budget} tokens this month).",
          "/console/fluxes/#{workflow.id}"
        )

        from(w in Workflow, where: w.id == ^workflow.id)
        |> Repo.update_all([set: [budget_warned_month: month]], skip_workspace_guard: true)

        :ok

      true ->
        :ok
    end
  end

  # A max_concurrent_runs setting caps simultaneous interactive runs
  # (drafts, API, sites) — batch and eval rows already execute
  # sequentially inside their workers and stay exempt.
  defp check_concurrency(_workspace_id, source) when source in [:batch, :eval], do: :ok

  defp check_concurrency(workspace_id, _source) do
    case Repo.get(Flux.Accounts.Workspace, workspace_id) do
      %{custom_config: %{"max_concurrent_runs" => cap}} when is_integer(cap) and cap > 0 ->
        running =
          WorkflowRun
          |> where([r], r.workspace_id == ^workspace_id and r.status == :running)
          |> Repo.aggregate(:count, skip_workspace_guard: true)

        if running >= cap, do: {:error, :concurrency_limit}, else: :ok

      _uncapped ->
        :ok
    end
  end

  # A monthly token budget in workspace settings gates new runs: past the
  # cap they refuse with :budget_exhausted; at 80% a notification fires
  # (once per month).
  defp check_token_budget(workspace_id) do
    case Repo.get(Flux.Accounts.Workspace, workspace_id) do
      %{custom_config: %{"monthly_token_budget" => budget} = config} = workspace
      when is_integer(budget) ->
        spent = Flux.Usage.month_tokens(workspace_id)
        month = Calendar.strftime(Date.utc_today(), "%Y-%m")

        cond do
          spent >= budget ->
            {:error, :budget_exhausted}

          spent >= budget * 0.8 and config["budget_warned"] != month ->
            Flux.Notifications.notify(
              workspace_id,
              "budget_warning",
              "Token budget 80% spent: #{spent} of #{budget} this month.",
              "/console/runs"
            )

            workspace
            |> Ecto.Changeset.change(custom_config: Map.put(config, "budget_warned", month))
            |> Repo.update()

            :ok

          true ->
            :ok
        end

      _no_budget ->
        :ok
    end
  end

  defp do_start_run(scope, workflow, graph_map, inputs, opts) do
    case Engine.build(graph_map) do
      {:ok, graph} ->
        run =
          Repo.insert!(%WorkflowRun{
            workspace_id: workflow.workspace_id,
            workflow_id: workflow.id,
            status: :running,
            source: Keyword.get(opts, :source, :draft),
            version: Keyword.get(opts, :version),
            inputs: inputs
          })

        :ok = subscribe(run.id)
        workspace_id = Scope.workspace_id(scope)
        run_opts = Keyword.take(opts, [:sys, :conversation])

        {:ok, _pid} =
          Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
            Registry.register(Flux.GenerationRegistry, run.id, nil)
            execute(run, graph, inputs, workspace_id, run_opts)
          end)

        {:ok, run}

      {:error, errors} ->
        {:error, {:invalid_graph, errors}}
    end
  end

  ## Batch runs

  @max_batch_rows 200

  @doc """
  Starts a batch: the target graph (`version: nil` = draft, or a
  published version number) is validated and snapshotted, one run per
  row executes sequentially in an Oban job, and counters advance as
  rows land (watch `batch_topic/1`). Caps at #{@max_batch_rows} rows.
  """
  def start_batch(%Scope{} = scope, %Workflow{} = workflow, rows, opts \\ [])
      when is_list(rows) do
    cond do
      rows == [] ->
        {:error, :empty}

      length(rows) > @max_batch_rows ->
        {:error, {:too_many_rows, @max_batch_rows}}

      true ->
        with {:ok, graph_map, target} <-
               resolve_batch_target(scope, workflow, Keyword.get(opts, :version)),
             {:ok, _graph} <- validate_batch_graph(graph_map) do
          batch =
            Repo.insert!(%WorkflowBatch{
              workspace_id: Scope.workspace_id(scope),
              workflow_id: workflow.id,
              name: Keyword.get(opts, :name, "batch"),
              target: target,
              graph: graph_map,
              rows: rows,
              total: length(rows)
            })

          {:ok, _job} =
            %{"batch_id" => batch.id}
            |> Flux.Workflows.BatchWorker.new()
            |> Oban.insert()

          {:ok, batch}
        end
    end
  end

  defp resolve_batch_target(_scope, workflow, nil), do: {:ok, workflow.graph, "draft"}

  defp resolve_batch_target(scope, workflow, version) when is_integer(version) do
    case get_version(scope, workflow.id, version) do
      %WorkflowVersion{graph: graph} -> {:ok, graph, "v#{version}"}
      {:error, :not_found} -> {:error, :version_not_found}
    end
  end

  defp validate_batch_graph(graph_map) do
    case Engine.build(graph_map) do
      {:ok, graph} -> {:ok, graph}
      {:error, errors} -> {:error, {:invalid_graph, errors}}
    end
  end

  def list_batches(%Scope{} = scope, workflow_id) do
    WorkflowBatch
    |> Repo.scoped(scope)
    |> where([b], b.workflow_id == ^workflow_id)
    |> order_by([b], desc: b.inserted_at)
    |> limit(50)
    |> Repo.all()
  end

  def get_batch(%Scope{} = scope, batch_id) do
    Repo.one(Repo.scoped(where(WorkflowBatch, id: ^batch_id), scope)) || {:error, :not_found}
  end

  @doc "A batch's runs in row order."
  def list_batch_runs(%Scope{} = scope, batch_id) do
    WorkflowRun
    |> Repo.scoped(scope)
    |> where([r], r.batch_id == ^batch_id)
    |> order_by([r], asc: r.inserted_at, asc: r.id)
    |> Repo.all()
  end

  @doc """
  Starts a new batch over only the failed rows of a completed batch —
  rows match runs by order, and the new batch targets the same
  draft/version the original did.
  """
  def retry_failed_rows(%Scope{} = scope, batch_id) do
    with %WorkflowBatch{status: :completed} = batch <- get_batch(scope, batch_id),
         %Workflow{} = workflow <-
           Repo.get_by(Workflow, [id: batch.workflow_id], skip_workspace_guard: true) ||
             {:error, :not_found} do
      failed_rows =
        scope
        |> list_batch_runs(batch_id)
        |> Enum.with_index()
        |> Enum.filter(fn {run, _index} -> run.status == :failed end)
        |> Enum.map(fn {_run, index} -> Enum.at(batch.rows, index) end)
        |> Enum.reject(&is_nil/1)

      version =
        case batch.target do
          "v" <> number -> String.to_integer(number)
          _draft -> nil
        end

      case failed_rows do
        [] ->
          {:error, :nothing_failed}

        rows ->
          start_batch(scope, workflow, rows, name: batch.name <> " (retry)", version: version)
      end
    else
      %WorkflowBatch{} -> {:error, :still_running}
      error -> error
    end
  end

  ## Batch schedules (recurring batches on a cron)

  @doc "Saves a completed batch's row set as a recurring cron schedule."
  def schedule_batch(%Scope{} = scope, batch_id, cron) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %WorkflowBatch{} = batch <- get_batch(scope, batch_id) do
      %Flux.Workflows.BatchSchedule{
        workspace_id: batch.workspace_id,
        workflow_id: batch.workflow_id
      }
      |> Flux.Workflows.BatchSchedule.changeset(%{
        "name" => batch.name,
        "rows" => batch.rows,
        "cron" => cron,
        "target" => batch.target
      })
      |> Repo.insert()
    end
  end

  def list_batch_schedules(%Scope{} = scope, workflow_id) do
    Flux.Workflows.BatchSchedule
    |> Repo.scoped(scope)
    |> where([s], s.workflow_id == ^workflow_id)
    |> order_by([s], asc: s.inserted_at)
    |> Repo.all()
  end

  def toggle_batch_schedule(%Scope{} = scope, schedule_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Flux.Workflows.BatchSchedule{} = schedule <-
           Repo.one(Repo.scoped(where(Flux.Workflows.BatchSchedule, id: ^schedule_id), scope)) ||
             {:error, :not_found} do
      schedule |> Ecto.Changeset.change(enabled: not schedule.enabled) |> Repo.update()
    end
  end

  def delete_batch_schedule(%Scope{} = scope, schedule_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Flux.Workflows.BatchSchedule{} = schedule <-
           Repo.one(Repo.scoped(where(Flux.Workflows.BatchSchedule, id: ^schedule_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(schedule)
    end
  end

  @doc """
  Minute-tick sweep: starts a batch for every enabled schedule whose
  cron matches this minute (`last_run_at` suppresses double fires).
  """
  def run_scheduled_batches(now \\ DateTime.utc_now(:second)) do
    minute_start = %{now | second: 0}

    schedules =
      Flux.Workflows.BatchSchedule
      |> where([s], s.enabled == true)
      |> Repo.all(skip_workspace_guard: true)

    for schedule <- schedules,
        batch_cron_due?(schedule.cron, now),
        schedule.last_run_at == nil or
          DateTime.compare(schedule.last_run_at, minute_start) == :lt do
      scope = batch_worker_scope(schedule.workspace_id)

      {:ok, _updated} =
        schedule |> Ecto.Changeset.change(last_run_at: now) |> Repo.update()

      with %Workflow{} = workflow <- get_workflow(scope, schedule.workflow_id),
           {:ok, batch} <-
             start_batch(scope, workflow, schedule.rows,
               name: schedule.name,
               version: parse_schedule_version(schedule.target)
             ) do
        batch
      else
        _error -> nil
      end
    end
    |> Enum.filter(& &1)
  end

  defp batch_cron_due?(cron, now) do
    case Oban.Cron.Expression.parse(cron) do
      {:ok, expression} -> Oban.Cron.Expression.now?(expression, now)
      {:error, _reason} -> false
    end
  end

  defp parse_schedule_version("v" <> version) do
    case Integer.parse(version) do
      {n, ""} -> n
      _invalid -> nil
    end
  end

  defp parse_schedule_version(_draft), do: nil

  defp batch_worker_scope(workspace_id) do
    %Scope{
      workspace: %Flux.Accounts.Workspace{id: workspace_id},
      membership: %Flux.Accounts.Membership{workspace_id: workspace_id, role: :editor}
    }
  end

  def batch_topic(workflow_id), do: "workflow_batches:#{workflow_id}"

  def subscribe_batches(workflow_id),
    do: Phoenix.PubSub.subscribe(Flux.PubSub, batch_topic(workflow_id))

  @doc false
  # Executed inside Flux.Workflows.BatchWorker: rows run sequentially so
  # a batch can't starve interactive runs of provider throughput.
  def perform_batch(batch_id) do
    batch = Repo.get(WorkflowBatch, batch_id, skip_workspace_guard: true)

    with %WorkflowBatch{status: :running} <- batch,
         {:ok, graph} <- Engine.build(batch.graph) do
      Enum.each(batch.rows, fn row ->
        run =
          Repo.insert!(%WorkflowRun{
            workspace_id: batch.workspace_id,
            workflow_id: batch.workflow_id,
            batch_id: batch.id,
            status: :running,
            source: :batch,
            inputs: row
          })

        {:ok, finished} = do_execute(run, graph, row, batch.workspace_id, [])

        counter = if finished.status == :succeeded, do: :succeeded, else: :failed

        from(b in WorkflowBatch, where: b.id == ^batch.id)
        |> Repo.update_all([inc: [{counter, 1}]], skip_workspace_guard: true)

        broadcast_batch(batch)
      end)

      from(b in WorkflowBatch, where: b.id == ^batch.id)
      |> Repo.update_all([set: [status: "completed"]], skip_workspace_guard: true)

      broadcast_batch(batch)

      finished = Repo.get(WorkflowBatch, batch.id, skip_workspace_guard: true)

      Flux.Webhooks.dispatch(batch.workspace_id, "batch.completed", %{
        "batch_id" => batch.id,
        "workflow_id" => batch.workflow_id,
        "name" => batch.name,
        "total" => finished.total,
        "succeeded" => finished.succeeded,
        "failed" => finished.failed
      })
    end

    :ok
  end

  @doc false
  # Synchronous single-run execution for Flux.Evals — same lifecycle as
  # any run (usage, webhooks, PubSub), just awaited by the caller.
  def execute_for_eval(%WorkflowRun{} = run, graph, inputs) do
    do_execute(run, graph, inputs, run.workspace_id, [])
  end

  defp broadcast_batch(batch) do
    Phoenix.PubSub.broadcast(
      Flux.PubSub,
      batch_topic(batch.workflow_id),
      {:batch_updated, batch.id}
    )
  end

  @doc """
  Workspace-wide run history with workflow names — the `/console/runs`
  page. `filters` may carry `:workflow_id`, `:source`, `:status`.
  """
  def list_workspace_runs(%Scope{} = scope, filters \\ %{}, limit \\ 100) do
    WorkflowRun
    |> Repo.scoped(scope)
    |> join(:inner, [r], w in Workflow, on: r.workflow_id == w.id)
    |> filter_runs(filters)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> select([r, w], %{run: r, workflow_name: w.name})
    |> Repo.all()
  end

  defp filter_runs(query, filters) do
    query
    |> then(fn q ->
      case filters[:workflow_id] do
        nil -> q
        workflow_id -> where(q, [r], r.workflow_id == ^workflow_id)
      end
    end)
    |> then(fn q ->
      case filters[:source] do
        nil -> q
        source -> where(q, [r], r.source == ^source)
      end
    end)
    |> then(fn q ->
      case filters[:status] do
        nil -> q
        status -> where(q, [r], r.status == ^status)
      end
    end)
    |> then(fn q ->
      case filters[:from] do
        %Date{} = from -> where(q, [r], r.inserted_at >= ^DateTime.new!(from, ~T[00:00:00]))
        _none -> q
      end
    end)
    |> then(fn q ->
      case filters[:to] do
        %Date{} = to ->
          where(q, [r], r.inserted_at < ^DateTime.new!(Date.add(to, 1), ~T[00:00:00]))

        _none ->
          q
      end
    end)
    |> then(fn q ->
      case String.trim(to_string(filters[:q] || "")) do
        "" ->
          q

        text ->
          pattern = "%" <> String.replace(text, ~r/[\\%_]/, fn c -> "\\" <> c end) <> "%"

          where(
            q,
            [r],
            fragment("?::text ILIKE ?", r.inputs, ^pattern) or
              fragment("?::text ILIKE ?", r.outputs, ^pattern)
          )
      end
    end)
  end

  @doc "The workspace's fluxes as {name, id} options (runs page filter)."
  def workflow_options(%Scope{} = scope) do
    Workflow
    |> Repo.scoped(scope)
    |> where([w], is_nil(w.deleted_at))
    |> order_by([w], asc: w.name)
    |> select([w], {w.name, w.id})
    |> Repo.all()
  end

  @doc "PubSub topic carrying a run's engine events."
  def topic(run_id), do: "workflow_run:#{run_id}"

  def subscribe(run_id), do: Phoenix.PubSub.subscribe(Flux.PubSub, topic(run_id))

  @doc "Kills an in-flight run; the row is marked `:stopped`."
  def stop_run(%Scope{} = scope, run_id) do
    case Repo.one(Repo.scoped(where(WorkflowRun, id: ^run_id), scope)) do
      %WorkflowRun{status: :running} = run ->
        case Registry.lookup(Flux.GenerationRegistry, run_id) do
          [{pid, _value}] -> Process.exit(pid, :kill)
          [] -> :ok
        end

        finalize(run, %{status: :stopped})

      _other ->
        {:error, :not_running}
    end
  end

  def get_run(%Scope{} = scope, run_id) do
    Repo.one(Repo.scoped(where(WorkflowRun, id: ^run_id), scope)) || {:error, :not_found}
  end

  def list_runs(%Scope{} = scope, workflow_id, limit \\ 20) do
    WorkflowRun
    |> Repo.scoped(scope)
    |> where([r], r.workflow_id == ^workflow_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  ## Triggers

  def create_trigger(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         :ok <- owned(scope, workflow),
         :ok <- verify_trigger_plugin(workflow.workspace_id, attrs) do
      token =
        if attrs["type"] in [:webhook, "webhook"] do
          "wht_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        end

      with {:ok, trigger} <-
             %Flux.Workflows.Trigger{
               workspace_id: workflow.workspace_id,
               workflow_id: workflow.id,
               token: token
             }
             |> Flux.Workflows.Trigger.changeset(attrs)
             |> Repo.insert() do
        Flux.Audit.record(scope, "trigger.create",
          resource: trigger,
          metadata: %{"type" => to_string(trigger.type), "workflow_id" => workflow.id}
        )

        {:ok, trigger}
      end
    end
  end

  # Plugin triggers must name a plugin installed in the workspace.
  defp verify_trigger_plugin(workspace_id, attrs) do
    if attrs["type"] in [:plugin, "plugin"] do
      plugin_id = attrs["plugin_id"] || ""

      if plugin_id != "" and Flux.Tools.plugin_installed?(workspace_id, plugin_id) do
        :ok
      else
        {:error, :plugin_not_installed}
      end
    else
      :ok
    end
  end

  def list_triggers(%Scope{} = scope, workflow_id) do
    Flux.Workflows.Trigger
    |> Repo.scoped(scope)
    |> where([t], t.workflow_id == ^workflow_id)
    |> Repo.all()
  end

  def delete_trigger(%Scope{} = scope, trigger_id) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      case Repo.one(Repo.scoped(where(Flux.Workflows.Trigger, id: ^trigger_id), scope)) do
        nil ->
          {:error, :not_found}

        trigger ->
          with {:ok, deleted} <- Repo.delete(trigger) do
            Flux.Audit.record(scope, "trigger.delete", resource: trigger)
            {:ok, deleted}
          end
      end
    end
  end

  ## Site publishing

  @doc """
  Publishes the flux at a public form URL (`/site/flux/:token`). The token
  is minted once and survives disable/enable so the URL stays stable.
  """
  def enable_site(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         :ok <- owned(scope, workflow) do
      token =
        workflow.site_token ||
          "site_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      with {:ok, updated} <-
             workflow
             |> Ecto.Changeset.change(site_token: token, site_enabled: true)
             |> Repo.update() do
        Flux.Audit.record(scope, "workflow.site_enable", resource: workflow)
        {:ok, updated}
      end
    end
  end

  def disable_site(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         :ok <- owned(scope, workflow),
         {:ok, updated} <-
           workflow |> Ecto.Changeset.change(site_enabled: false) |> Repo.update() do
      Flux.Audit.record(scope, "workflow.site_disable", resource: workflow)
      {:ok, updated}
    end
  end

  @doc "Saves the public form page's theme (accent/title/logo_url)."
  def set_site_theme(%Scope{} = scope, %Workflow{} = workflow, theme) when is_map(theme) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         :ok <- owned(scope, workflow),
         {:ok, updated} <-
           workflow
           |> Ecto.Changeset.change(site_theme: Map.take(theme, ~w(accent title logo_url)))
           |> Repo.update() do
      Flux.Audit.record(scope, "workflow.site_theme", resource: workflow)
      {:ok, updated}
    end
  end

  @doc """
  Exports a finished run as a golden fixture: the exact graph it ran,
  its inputs, and what happened — replayable by the golden test suite
  (deterministic on the echo provider) to pin graph semantics in CI.
  """
  def export_run_fixture(%Scope{} = scope, run_id) do
    with :ok <- RBAC.authorize(scope, :app_import_export_dsl),
         %WorkflowRun{} = run <- as_found(get_run(scope, run_id)),
         true <- run.status in [:succeeded, :failed] || {:error, :not_finished},
         %Workflow{} = workflow <- as_found(get_workflow(scope, run.workflow_id)) do
      graph =
        with version when is_integer(version) <- run.version,
             %WorkflowVersion{graph: graph} <- get_version(scope, workflow.id, version) do
          graph
        else
          _draft_run -> workflow.graph
        end

      {:ok,
       %{
         "format" => "fluxcapacitor-run-fixture",
         "version" => 1,
         "name" => workflow.name,
         "graph" => graph,
         "inputs" => run.inputs,
         "expected" => %{
           "status" => to_string(run.status),
           "outputs" => run.outputs,
           "error" => run.error,
           "node_sequence" =>
             Enum.map(run.node_executions, fn execution ->
               %{"node_id" => execution["node_id"], "status" => execution["status"]}
             end)
         }
       }}
    end
  end

  defp as_found(%{} = struct), do: struct
  defp as_found({:error, reason}), do: {:error, reason}

  @doc "Resolves a public site token to its flux; the token is the authorization."
  def get_workflow_by_site_token("site_" <> _rest = token) do
    case Repo.get_by(Workflow, [site_token: token], skip_workspace_guard: true) do
      %Workflow{site_enabled: true, deleted_at: nil} = workflow -> {:ok, workflow}
      _disabled_trashed_or_missing -> {:error, :not_found}
    end
  end

  def get_workflow_by_site_token(_other), do: {:error, :not_found}

  @doc "A workspace-only scope for anonymous public-site visitors."
  def site_scope(%Workflow{} = workflow) do
    %Scope{
      account: nil,
      membership: nil,
      workspace: %Flux.Accounts.Workspace{id: workflow.workspace_id}
    }
  end

  def set_trigger_enabled(%Scope{} = scope, trigger_id, enabled) when is_boolean(enabled) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      case Repo.one(Repo.scoped(where(Flux.Workflows.Trigger, id: ^trigger_id), scope)) do
        nil -> {:error, :not_found}
        trigger -> trigger |> Ecto.Changeset.change(enabled: enabled) |> Repo.update()
      end
    end
  end

  def fetch_trigger_by_token("wht_" <> _rest = token) do
    case Repo.get_by(Flux.Workflows.Trigger, [token: token], skip_workspace_guard: true) do
      %Flux.Workflows.Trigger{enabled: true} = trigger -> {:ok, trigger}
      _disabled_or_missing -> {:error, :not_found}
    end
  end

  def fetch_trigger_by_token(_other), do: {:error, :not_found}

  @doc """
  Starts a published run for a trigger (webhook payload merges over the
  trigger's static inputs) and stamps `last_run_at`.
  """
  def run_from_trigger(%Flux.Workflows.Trigger{} = trigger, input_override \\ %{}) do
    scope = %Scope{
      account: nil,
      membership: nil,
      workspace: %Flux.Accounts.Workspace{id: trigger.workspace_id}
    }

    with %Workflow{deleted_at: nil} = workflow <-
           Repo.get_by(Workflow, [id: trigger.workflow_id], skip_workspace_guard: true) ||
             {:error, :not_found},
         %WorkflowVersion{} = version <-
           serving_version(scope, workflow) || {:error, :not_published} do
      trigger
      |> Ecto.Changeset.change(last_run_at: DateTime.utc_now(:second))
      |> Repo.update()

      start_run(scope, workflow, Map.merge(trigger.inputs, input_override),
        source: :api,
        graph: version.graph,
        version: version.version
      )
    end
  end

  @doc """
  Runs the latest published version synchronously and returns the
  finished run — inbound integrations (MCP `tools/call`) await outputs.
  Same lifecycle as any run: usage, webhooks, budget and guardrails.
  """
  def run_published_sync(%Scope{} = scope, %Workflow{} = workflow, inputs) when is_map(inputs) do
    with %WorkflowVersion{} = version <-
           serving_version(scope, workflow) || {:error, :not_published},
         :ok <- check_token_budget(workflow.workspace_id),
         :ok <- check_flux_budget(workflow),
         :ok <-
           Flux.Guardrails.check_input(
             workflow.workspace_id,
             Jason.encode!(inputs),
             "run input (#{workflow.name})"
           ),
         {:ok, graph} <- Engine.build(version.graph) do
      run =
        Repo.insert!(%WorkflowRun{
          workspace_id: workflow.workspace_id,
          workflow_id: workflow.id,
          status: :running,
          source: :api,
          version: version.version,
          inputs: inputs
        })

      do_execute(run, graph, inputs, workflow.workspace_id, [])
    end
  end

  ## API tokens

  def create_api_token(%Scope{} = scope, %Workflow{} = workflow, opts \\ []) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         :ok <- owned(scope, workflow) do
      raw = "flux-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      token =
        Repo.insert!(%ApiToken{
          workspace_id: workflow.workspace_id,
          workflow_id: workflow.id,
          token_hash: :crypto.hash(:sha256, raw),
          prefix: String.slice(raw, 0, 13) <> "…",
          expires_at: Flux.Chat.token_expiry(opts[:expires_in_days])
        })

      Flux.Audit.record(scope, "api_token.create",
        resource: token,
        metadata: %{"workflow_id" => workflow.id, "prefix" => token.prefix}
      )

      {:ok, token, raw}
    end
  end

  def list_api_tokens(%Scope{} = scope, workflow_id) do
    ApiToken |> Repo.scoped(scope) |> where([t], t.workflow_id == ^workflow_id) |> Repo.all()
  end

  def revoke_api_token(%Scope{} = scope, token_id) do
    case Repo.one(Repo.scoped(where(ApiToken, id: ^token_id), scope)) do
      nil ->
        {:error, :not_found}

      token ->
        with {:ok, deleted} <- Repo.delete(token) do
          Flux.Audit.record(scope, "api_token.revoke",
            resource: token,
            metadata: %{"prefix" => token.prefix}
          )

          {:ok, deleted}
        end
    end
  end

  @doc "Resolves a raw `flux-…` bearer token to `{workflow, token}`."
  def fetch_workflow_by_token("flux-" <> _rest = raw) do
    hash = :crypto.hash(:sha256, raw)

    # Token possession is the authorization; the lookup is cross-workspace.
    case Repo.get_by(ApiToken, [token_hash: hash], skip_workspace_guard: true) do
      %ApiToken{workflow_id: workflow_id} = token when not is_nil(workflow_id) ->
        cond do
          Flux.Chat.token_expired?(token) ->
            {:error, :token_expired}

          true ->
            token
            |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
            |> Repo.update()

            case Repo.get!(Workflow, workflow_id, skip_workspace_guard: true) do
              %Workflow{deleted_at: nil} = workflow -> {:ok, workflow, token}
              _trashed -> {:error, :invalid_token}
            end
        end

      _other ->
        {:error, :invalid_token}
    end
  end

  def fetch_workflow_by_token(_other), do: {:error, :invalid_token}

  ## Run internals

  @doc """
  Starts a NEW run that replays a finished run from `from_node_id`:
  every node upstream of (or parallel to) the target reuses its recorded
  outputs, while the target and its descendants execute fresh. The
  original run is untouched. Chatflow `sys` context is not reconstructed
  — replay is built for draft/API/batch debugging.
  """
  def replay_run(%Scope{} = scope, run_id, from_node_id) do
    with %WorkflowRun{} = source <-
           Repo.one(Repo.scoped(where(WorkflowRun, id: ^run_id), scope)) ||
             {:error, :not_found},
         true <- source.status in [:succeeded, :failed] || {:error, :not_finished},
         %Workflow{} = workflow <-
           Repo.get_by(Workflow, [id: source.workflow_id], skip_workspace_guard: true) ||
             {:error, :not_found},
         {:ok, graph} <- Engine.build(run_graph(scope, workflow, source)),
         true <- Map.has_key?(graph.nodes, from_node_id) || {:error, :unknown_node} do
      fresh = replay_fresh_ids(graph, from_node_id)

      recorded =
        for execution <- source.node_executions || [],
            id = execution["node_id"],
            Map.has_key?(graph.nodes, id) and id not in fresh,
            into: %{} do
          {id, execution["outputs"] || %{}}
        end

      conversation_defaults =
        Map.new(graph.conversation_variables, fn variable ->
          {variable["name"], variable["default"]}
        end)

      pool =
        Map.merge(
          %{"env" => graph.env, "sys" => %{}, "conversation" => conversation_defaults},
          recorded
        )

      run =
        Repo.insert!(%WorkflowRun{
          workspace_id: workflow.workspace_id,
          workflow_id: workflow.id,
          status: :running,
          source: source.source,
          version: source.version,
          inputs: source.inputs
        })

      :ok = subscribe(run.id)

      resume = %{pool: pool, node_id: from_node_id, input: nil, rerun: true}

      {:ok, _pid} =
        Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
          Registry.register(Flux.GenerationRegistry, run.id, nil)
          do_execute(run, graph, %{}, workflow.workspace_id, resume: resume)
        end)

      {:ok, run}
    else
      false -> {:error, :not_finished}
      {:error, errors} when is_list(errors) -> {:error, {:invalid_graph, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The target and everything reachable from it — the set that runs fresh.
  defp replay_fresh_ids(graph, from_node_id) do
    grow = fn grow, frontier, seen ->
      next =
        graph.edges
        |> Enum.filter(&(&1.source in frontier))
        |> Enum.map(& &1.target)
        |> MapSet.new()
        |> MapSet.difference(seen)

      if MapSet.size(next) == 0 do
        seen
      else
        grow.(grow, next, MapSet.union(seen, next))
      end
    end

    grow.(grow, MapSet.new([from_node_id]), MapSet.new([from_node_id]))
  end

  defp execute(run, graph, inputs, workspace_id, run_opts) do
    require OpenTelemetry.Tracer

    OpenTelemetry.Tracer.with_span "flux.workflow.run", %{
      attributes: %{
        "flux.run_id" => run.id,
        "flux.workflow_id" => run.workflow_id,
        "flux.source" => to_string(run.source),
        "flux.version" => run.version
      }
    } do
      do_execute(run, graph, inputs, workspace_id, run_opts)
    end
  end

  defp do_execute(run, graph, inputs, workspace_id, run_opts) do
    {:ok, usage_acc} = Agent.start_link(fn -> %{models: %{}, nodes: %{}} end)

    host =
      workspace_id
      |> build_host(
        fn event ->
          Phoenix.PubSub.broadcast(Flux.PubSub, topic(run.id), {:engine_event, event})
        end,
        0,
        run.id
      )
      |> track_llm_usage(usage_acc)

    result = Engine.run(graph, inputs, host, run_opts)
    usage = collect_usage(run, usage_acc)

    case result do
      {:ok, result} ->
        finalize(run, %{
          status: :succeeded,
          outputs: result.outputs,
          node_executions: run.node_executions ++ result.node_executions,
          elapsed_ms: result.elapsed_ms,
          usage: usage
        })

      {:paused, paused} ->
        finalize(run, %{
          status: :paused,
          node_executions: run.node_executions ++ paused.node_executions,
          elapsed_ms: paused.elapsed_ms,
          usage: usage,
          snapshot: %{
            "node_id" => paused.node_id,
            "prompt" => paused.prompt,
            "pool" => paused.pool
          }
        })

      {:error, failure} ->
        finalize(run, %{
          status: :failed,
          error: failure.error,
          node_executions: run.node_executions ++ failure.node_executions,
          elapsed_ms: failure.elapsed_ms,
          usage: usage
        })
    end
  end

  # Every model call in a run goes through the host's invoke_llm — llm,
  # agent, question_classifier, and parameter_extractor nodes alike — so
  # wrapping it here is the one place token usage can be counted whole.
  defp track_llm_usage(%Host{invoke_llm: invoke} = host, usage_acc) do
    %Host{
      host
      | invoke_llm: fn request, chunk_emit ->
          result = invoke.(request, chunk_emit)

          case result do
            {:ok, %{usage: %{} = usage}} ->
              # The engine stamps the executing node's id in the calling
              # process — per-node attribution rides the same wrapper.
              node_id = Process.get(:flux_engine_node_id) || "unknown"

              Agent.update(usage_acc, fn acc ->
                %{
                  acc
                  | models: add_model_usage(acc.models, request.model, usage),
                    nodes: add_model_usage(acc.nodes, node_id, usage)
                }
              end)

            _error_or_no_usage ->
              :ok
          end

          result
        end
    }
  end

  defp add_model_usage(by_model, model, usage) do
    increment = %{
      "input_tokens" => usage["input_tokens"] || 0,
      "output_tokens" => usage["output_tokens"] || 0
    }

    Map.update(by_model, model || "unknown", increment, fn existing ->
      %{
        "input_tokens" => existing["input_tokens"] + increment["input_tokens"],
        "output_tokens" => existing["output_tokens"] + increment["output_tokens"]
      }
    end)
  end

  # A resumed run already carries the usage from before the pause; merge
  # rather than overwrite so the final totals cover the whole run.
  defp collect_usage(run, usage_acc) do
    fresh = Agent.get(usage_acc, & &1)
    Agent.stop(usage_acc)

    by_model =
      Enum.reduce(fresh.models, run.usage["by_model"] || %{}, fn {model, usage}, acc ->
        add_model_usage(acc, model, usage)
      end)

    by_node =
      Enum.reduce(fresh.nodes, run.usage["by_node"] || %{}, fn {node_id, usage}, acc ->
        add_model_usage(acc, node_id, usage)
      end)

    if by_model == %{} do
      %{}
    else
      totals =
        Enum.reduce(by_model, %{input: 0, output: 0}, fn {_model, usage}, acc ->
          %{
            input: acc.input + usage["input_tokens"],
            output: acc.output + usage["output_tokens"]
          }
        end)

      base = %{
        "input_tokens" => totals.input,
        "output_tokens" => totals.output,
        "by_model" => by_model,
        "by_node" => by_node
      }

      case Flux.Pricing.cost_for(run.workspace_id, by_model) do
        nil -> base
        cost -> Map.put(base, "estimated_cost_usd", cost)
      end
    end
  end

  @doc """
  Resumes a paused run from a raw params map: interview pauses validate
  the answers against the snapshotted questions (returning
  `{:error, {:invalid_answers, %{name => message}}}` on failure), plain
  human-input pauses take `params["input"]`. The one resume entrypoint
  for the console, public sites, and `/v1`.
  """
  def resume_run_with_params(%Scope{} = scope, run_id, params) when is_map(params) do
    case Repo.one(Repo.scoped(where(WorkflowRun, id: ^run_id), scope)) do
      %WorkflowRun{status: :paused, snapshot: %{"prompt" => %{"questions" => questions}}}
      when is_list(questions) and questions != [] ->
        case Flux.Interviews.validate_answers(questions, params) do
          {:ok, answers} -> resume_run(scope, run_id, answers)
          {:error, errors} -> {:error, {:invalid_answers, errors}}
        end

      _plain_or_missing ->
        resume_run(scope, run_id, to_string(params["input"] || ""))
    end
  end

  @doc """
  Resumes a paused run with the human's input: flips the run back to
  `:running`, subscribes the caller to its topic, and continues the
  published/draft graph from the paused node in a supervised task.
  """
  def resume_run(%Scope{} = scope, run_id, input) do
    with %WorkflowRun{status: :paused, snapshot: %{} = snapshot} = run <-
           Repo.one(Repo.scoped(where(WorkflowRun, id: ^run_id), scope)) ||
             {:error, :not_found},
         %Workflow{} = workflow <-
           Repo.get_by(Workflow, [id: run.workflow_id], skip_workspace_guard: true) ||
             {:error, :not_found},
         {:ok, graph} <- Engine.build(run_graph(scope, workflow, run)) do
      run =
        run
        |> Ecto.Changeset.change(status: :running, snapshot: nil)
        |> Repo.update!()

      :ok = subscribe(run.id)

      # Tool-approval pauses re-run the agent node with the decision (and
      # the pause payload) in reach, instead of feeding outputs downstream.
      resume =
        case snapshot["prompt"] do
          %{"type" => "tool_approval"} = prompt ->
            %{
              pool: snapshot["pool"] || %{},
              node_id: snapshot["node_id"],
              input: %{"approved" => approval?(input), "prompt" => prompt},
              rerun: true
            }

          _plain ->
            %{
              pool: snapshot["pool"] || %{},
              node_id: snapshot["node_id"],
              input: input
            }
        end

      {:ok, _pid} =
        Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
          Registry.register(Flux.GenerationRegistry, run.id, nil)
          do_execute(run, graph, %{}, run.workspace_id, resume: resume)
        end)

      {:ok, run}
    else
      %WorkflowRun{} -> {:error, :not_paused}
      {:error, errors} when is_list(errors) -> {:error, {:invalid_graph, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approval?(%{"approved" => value}), do: value in [true, "true"]

  defp approval?(input) when is_binary(input) do
    normalized = input |> String.trim() |> String.downcase()
    normalized in ~w(approve approved yes true)
  end

  defp approval?(_other), do: false

  # A paused draft run resumes against the current draft; a versioned run
  # resumes against its recorded version.
  defp run_graph(_scope, workflow, %WorkflowRun{version: nil}), do: workflow.graph

  defp run_graph(scope, workflow, %WorkflowRun{version: version}) do
    case Repo.one(
           WorkflowVersion
           |> Repo.scoped(scope)
           |> where([v], v.workflow_id == ^workflow.id and v.version == ^version)
         ) do
      %WorkflowVersion{graph: graph} -> graph
      nil -> workflow.graph
    end
  end

  defp finalize(run, changes) do
    run = run |> Ecto.Changeset.change(changes) |> Repo.update!()

    usage = run.usage || %{}

    :telemetry.execute(
      [:flux, :workflow, :run, :finished],
      %{
        duration_ms: run.elapsed_ms || 0,
        input_tokens: usage["input_tokens"] || 0,
        output_tokens: usage["output_tokens"] || 0,
        # Prometheus counters are integers; track cost in micro-dollars.
        cost_microusd: round((usage["estimated_cost_usd"] || 0) * 1_000_000)
      },
      %{status: run.status, source: run.source, workspace_id: run.workspace_id}
    )

    if run.status == :failed do
      enqueue_alert(run)
      workflow = Repo.get(Workflow, run.workflow_id, skip_workspace_guard: true)

      Flux.Notifications.notify(
        run.workspace_id,
        "run_failed",
        "Run failed: #{(workflow && workflow.name) || "flux"} — #{run.error}",
        "/console/runs"
      )
    end

    if run.status == :succeeded and run.outputs != %{} do
      Flux.Guardrails.flag_output(run.workspace_id, Jason.encode!(run.outputs), "run output")
    end

    Flux.Webhooks.dispatch_run_event(run)

    Phoenix.PubSub.broadcast(Flux.PubSub, topic(run.id), {:run_finished, run})
    {:ok, run}
  end

  defp enqueue_alert(run) do
    workspace = Repo.get(Flux.Accounts.Workspace, run.workspace_id)

    with %{custom_config: %{"alert_url" => url}} when is_binary(url) <- workspace do
      workflow = Repo.get(Workflow, run.workflow_id, skip_workspace_guard: true)

      %{
        "url" => url,
        "secret" => workspace.custom_config["alert_secret"],
        "payload" => %{
          "event" => "run.failed",
          "run_id" => run.id,
          "workflow_id" => run.workflow_id,
          "workflow_name" => workflow && workflow.name,
          "error" => run.error,
          "source" => to_string(run.source),
          "failed_at" => DateTime.to_iso8601(run.updated_at)
        }
      }
      |> Flux.Workflows.AlertWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  defp build_host(workspace_id, emit, depth \\ 0, run_id \\ nil) do
    %Host{
      emit: emit,
      queue_label_task: fn %{project_id: project_id, data: data} = request ->
        Flux.Labeling.queue_from_run(
          workspace_id,
          run_id,
          project_id,
          data,
          request[:node_id]
        )
      end,
      invoke_llm: build_llm_invoker(workspace_id),
      invoke_tool: fn %{toolset_id: toolset_id, operation_id: operation_id, args: args} ->
        Flux.Tools.invoke_for_workspace(workspace_id, toolset_id, operation_id, args)
      end,
      http_request: &node_http_request/1,
      run_code: fn request -> Flux.CodeRunner.run(request, workspace_id) end,
      node_cache: %{
        get: fn key -> Flux.LLMCache.get(key) end,
        put: fn key, value, ttl -> Flux.LLMCache.put(key, value, ttl) end
      },
      read_document: fn %{file_id: file_id} -> Flux.Documents.extract(workspace_id, file_id) end,
      run_subflux: build_subflux_runner(workspace_id, depth),
      retrieve_knowledge: build_knowledge_retriever(workspace_id),
      fetch_doc_template: fn template_id ->
        Flux.DocTemplates.fetch_content(workspace_id, template_id)
      end,
      fetch_docx_template: fn template_id ->
        Flux.DocTemplates.fetch_docx(workspace_id, template_id)
      end,
      store_file: build_file_store(workspace_id),
      fetch_interview: fn interview_id ->
        Flux.Interviews.fetch(workspace_id, interview_id)
      end,
      default_llm: Providers.default_model_for_workspace(workspace_id)
    }
  end

  @docx_content_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  # Run outputs (filled documents) persist as uploaded files with an
  # unguessable download token — the token is the authorization, so the
  # same URL works from the console, public sites, and /v1 responses.
  defp build_file_store(workspace_id) do
    fn %{name: name, binary: binary} = request ->
      with {:ok, binary} <- maybe_convert(request[:format], binary) do
        store_run_output(workspace_id, name, binary)
      end
    end
  end

  defp maybe_convert("pdf", docx_binary), do: Flux.Pdf.convert_docx(docx_binary)
  defp maybe_convert("html_pdf", html), do: Flux.Pdf.convert_html(html)
  defp maybe_convert(_format, binary), do: {:ok, binary}

  @doc """
  Stores an arbitrary workspace file with a tokenized download (backups,
  scheduled exports) — same shelf as run outputs, so it shows on the
  Files page.
  """
  def store_workspace_file(workspace_id, name, binary) when is_binary(binary) do
    store_run_output(workspace_id, name, binary)
  end

  defp store_run_output(workspace_id, name, binary) do
    key = "run_outputs/#{workspace_id}/#{Ecto.UUID.generate()}-#{name}"
    token = "file_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    with :ok <- Flux.Storage.put(key, binary) do
      file =
        Repo.insert!(%Flux.Chat.UploadedFile{
          workspace_id: workspace_id,
          name: name,
          key: key,
          size: byte_size(binary),
          content_type: content_type_for(name),
          download_token: token
        })

      {:ok,
       %{
         "file_id" => file.id,
         "name" => name,
         "url" => "/files/#{token}",
         "size" => byte_size(binary)
       }}
    end
  end

  defp content_type_for(name) do
    case name |> Path.extname() |> String.downcase() do
      ".docx" -> @docx_content_type
      ".pdf" -> "application/pdf"
      ".html" -> "text/html; charset=utf-8"
      ".md" -> "text/markdown; charset=utf-8"
      ".txt" -> "text/plain; charset=utf-8"
      ".csv" -> "text/csv; charset=utf-8"
      ".json" -> "application/json"
      _other -> "application/octet-stream"
    end
  end

  @doc """
  The workspace's stored files, newest first — run outputs (documents,
  file_output, code artifacts) and chat uploads alike. Rows with a
  `download_token` are downloadable at `/files/:token`.
  """
  def list_workspace_files(%Scope{} = scope, limit \\ 100) do
    Flux.Chat.UploadedFile
    |> Repo.scoped(scope)
    |> order_by([f], desc: f.inserted_at, desc: f.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Resolves a run-file download token to its metadata and bytes. The
  token is the authorization (unguessable, minted per file).
  """
  def fetch_file_by_token("file_" <> _rest = token) do
    with %Flux.Chat.UploadedFile{} = file <-
           Repo.get_by(Flux.Chat.UploadedFile, [download_token: token],
             skip_workspace_guard: true
           ),
         {:ok, binary} <- Flux.Storage.get(file.key) do
      {:ok, %{name: file.name, content_type: file.content_type, binary: binary}}
    else
      _missing -> {:error, :not_found}
    end
  end

  def fetch_file_by_token(_token), do: {:error, :not_found}

  # Resolved at call time: core does not compile-depend on flux_rag
  # (dependency direction is flux_rag -> flux), mirroring the plugin
  # runtime indirection.
  defp build_knowledge_retriever(workspace_id) do
    fn %{dataset_ids: dataset_ids, query: query, top_k: top_k} = request ->
      rag = Application.get_env(:flux, :rag_module, Flux.RAG)
      scope = %Scope{workspace: %Flux.Accounts.Workspace{id: workspace_id}}

      cond do
        not Code.ensure_loaded?(rag) ->
          {:error, "knowledge retrieval is unavailable in this deployment"}

        true ->
          case rag.retrieve_many(scope, dataset_ids, query,
                 top_k: top_k,
                 tags: Map.get(request, :tags, [])
               ) do
            {:ok, []} when dataset_ids != [] ->
              # Distinguish "no matches" from "no such dataset".
              if Enum.any?(dataset_ids, &match?(%{}, safe_get_dataset(rag, scope, &1))) do
                {:ok, []}
              else
                {:error, "dataset not found"}
              end

            {:ok, hits} ->
              {:ok,
               Enum.map(hits, fn hit ->
                 %{
                   content: hit.content,
                   document_name: hit.document.name,
                   score: hit.score
                 }
               end)}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp safe_get_dataset(rag, scope, dataset_id) do
    case rag.get_dataset(scope, dataset_id) do
      {:error, _reason} -> nil
      dataset -> dataset
    end
  end

  # Iteration items run the sub-flux's published version inline (no run
  # rows, silent host) — depth-capped so sub-fluxes cannot nest further.
  defp build_subflux_runner(workspace_id, depth) do
    fn %{workflow_id: workflow_id, item: item, index: index} = request ->
      scope = %Scope{workspace: %Flux.Accounts.Workspace{id: workspace_id}}

      with :ok <- (depth < 1 && :ok) || {:error, "sub-fluxes cannot start their own sub-fluxes"},
           %Workflow{workspace_id: ^workspace_id, deleted_at: nil} = workflow <-
             Repo.get_by(Workflow, [id: workflow_id], skip_workspace_guard: true) ||
               {:error, "sub-flux not found"},
           %WorkflowVersion{} = version <-
             resolve_subflux_version(scope, workflow.id, request[:version]) ||
               {:error, subflux_version_error(request[:version])},
           {:ok, graph} <- Engine.build(version.graph) do
        sub_host = build_host(workspace_id, fn _event -> :ok end, depth + 1)
        item_text = if is_binary(item), do: item, else: Jason.encode!(item)

        case Engine.run(graph, %{"item" => item_text, "index" => index}, sub_host,
               sys: %{"item" => item, "index" => index}
             ) do
          {:ok, result} -> {:ok, result.outputs}
          {:paused, _paused} -> {:error, "sub-fluxes cannot pause for human input"}
          {:error, failure} -> {:error, failure.error}
        end
      else
        %Workflow{} -> {:error, "sub-flux not found"}
        {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A pinned version makes composed fluxes reproducible; unpinned stays
  # "latest published".
  defp resolve_subflux_version(scope, workflow_id, nil), do: latest_version(scope, workflow_id)

  defp resolve_subflux_version(scope, workflow_id, version) when is_integer(version) do
    get_version(scope, workflow_id, version)
    |> case do
      %WorkflowVersion{} = found -> found
      _missing -> nil
    end
  end

  defp subflux_version_error(nil), do: "sub-flux has no published version"
  defp subflux_version_error(version), do: "sub-flux version v#{version} does not exist"

  @debug_timeout 60_000

  @doc """
  Runs a single draft node against a mock variable pool (selector strings
  → values, e.g. `%{"start.query" => "hi"}`) with the full production
  host. Returns `{:ok, outputs}` or `{:error, message}`.
  """
  def debug_node(%Scope{} = scope, %Workflow{} = workflow, node_id, mock_pool) do
    with :ok <- RBAC.authorize(scope, :app_test_and_run),
         :ok <- owned(scope, workflow),
         %{} = raw <-
           Enum.find(workflow.graph["nodes"] || [], &(&1["id"] == node_id)) ||
             {:error, :not_found} do
      node = %Flux.Engine.Graph.Node{
        id: raw["id"],
        type: raw["type"],
        title: raw["title"] || "",
        config: raw["config"] || %{}
      }

      pool = nest_mock_pool(mock_pool)
      host = build_host(workflow.workspace_id, fn _event -> :ok end)

      task =
        Task.Supervisor.async_nolink(Flux.GenerationSupervisor, fn ->
          Flux.Engine.Node.implementation(node.type).run(node, pool, host)
        end)

      case Task.yield(task, @debug_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, outputs}} -> {:ok, outputs}
        {:ok, {:ok, outputs, _branch}} -> {:ok, outputs}
        {:ok, {:error, reason}} -> {:error, debug_error(reason)}
        {:exit, reason} -> {:error, "node crashed: #{inspect(reason)}"}
        nil -> {:error, "the node did not finish within 60s"}
      end
    end
  end

  # %{"llm_1.text" => "hi"} → %{"llm_1" => %{"text" => "hi"}} (deep).
  defp nest_mock_pool(mock_pool) do
    Enum.reduce(mock_pool, %{}, fn {selector, value}, pool ->
      path = selector |> to_string() |> String.split(".")
      put_in(pool, Enum.map(path, &Access.key(&1, %{})), value)
    end)
  end

  defp debug_error(reason) when is_binary(reason), do: reason
  defp debug_error(reason), do: inspect(reason)

  @doc """
  One-shot call to the workspace default model (no streaming, no tools) —
  the Copilot's path to a completion. `{:error, :no_default_model}` when
  the workspace has none configured.
  """
  def invoke_default_llm(%Scope{} = scope, messages) do
    invoke_default_llm_for_workspace(Scope.workspace_id(scope), messages)
  end

  @doc "One-shot call to a *specific* provider/model (eval judges, workers)."
  def invoke_model_for_workspace(workspace_id, plugin_id, model, messages) do
    request = %{provider_plugin_id: plugin_id, model: model, messages: messages, params: %{}}

    case build_llm_invoker(workspace_id).(request, fn _chunk -> :ok end) do
      {:ok, %{content: content}} -> {:ok, content}
      {:error, reason} -> {:error, "the model errored: #{inspect(reason)}"}
    end
  end

  @doc "Like `invoke_default_llm/2` for callers that only hold a workspace id (workers)."
  def invoke_default_llm_for_workspace(workspace_id, messages) do
    case Providers.default_model_for_workspace(workspace_id) do
      %{"provider_plugin_id" => plugin_id, "model" => model} ->
        request = %{
          provider_plugin_id: plugin_id,
          model: model,
          messages: messages,
          params: %{}
        }

        case build_llm_invoker(workspace_id).(request, fn _chunk -> :ok end) do
          {:ok, %{content: content}} -> {:ok, content}
          {:error, reason} -> {:error, "the default model errored: #{inspect(reason)}"}
        end

      nil ->
        {:error, :no_default_model}
    end
  end

  defp build_llm_invoker(workspace_id) do
    cache_ttl = llm_cache_minutes(workspace_id)

    fn request, chunk_emit ->
      cache_key = cache_ttl > 0 && Flux.LLMCache.key(workspace_id, request)

      case cache_key && Flux.LLMCache.get(cache_key) do
        {:ok, cached} ->
          if is_binary(cached.content) and cached.content != "", do: chunk_emit.(cached.content)

          {:ok,
           %{
             cached
             | usage: %{"input_tokens" => 0, "output_tokens" => 0, "cached" => true}
           }}

        _miss_or_disabled ->
          invoke_llm_fresh(workspace_id, request, chunk_emit, cache_key, cache_ttl)
      end
    end
  end

  defp llm_cache_minutes(workspace_id) do
    case Repo.get(Flux.Accounts.Workspace, workspace_id) do
      %{custom_config: %{"llm_cache_minutes" => minutes}} when is_integer(minutes) -> minutes
      _off -> 0
    end
  end

  defp invoke_llm_fresh(workspace_id, request, chunk_emit, cache_key, cache_ttl) do
    credentials =
      case Providers.fetch_config(workspace_id, request.provider_plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    tools =
      for tool <- Map.get(request, :tools, []) do
        %Flux.Plugin.ModelProvider.ToolDef{
          name: tool["name"],
          description: tool["description"] || "",
          parameters: tool["parameters"] || %{"type" => "object", "properties" => %{}}
        }
      end

    provider_request = %Flux.Plugin.ModelProvider.Request{
      model: request.model,
      messages: request.messages,
      params: atomize_params(request.params),
      tools: tools
    }

    emit = fn %{delta: delta} -> chunk_emit.(delta) end

    case runtime().invoke_llm(request.provider_plugin_id, credentials, provider_request, emit) do
      {:ok, result} ->
        Flux.ProviderHealth.record(request.provider_plugin_id, :ok)

        response = %{
          content: result.content,
          usage: %{
            "input_tokens" => result.usage.input_tokens,
            "output_tokens" => result.usage.output_tokens
          },
          tool_calls: result.tool_calls
        }

        if cache_key, do: Flux.LLMCache.put(cache_key, response, cache_ttl)
        {:ok, response}

      {:error, reason} ->
        Flux.ProviderHealth.record(request.provider_plugin_id, :error)
        {:error, reason}
    end
  end

  # Host capability for the http_request node: SSRF-guarded raw request.
  defp node_http_request(%{method: method, url: url, headers: headers, body: body}) do
    with :ok <- Flux.SSRF.verify_url(url),
         {:ok, method} <- cast_method(method) do
      options =
        [method: method, url: url, headers: headers, receive_timeout: :timer.seconds(60)]
        |> then(fn options -> if body == "", do: options, else: options ++ [body: body] end)
        |> Keyword.merge(Application.get_env(:flux, :tools_req_options, []))

      case Req.request(options) do
        {:ok, %{status: status, body: response}} ->
          text = if is_binary(response), do: response, else: Jason.encode!(response)
          {:ok, %{status: status, body: response, text: text}}

        {:error, reason} ->
          {:error, "HTTP request failed: #{inspect(reason)}"}
      end
    end
  end

  defp cast_method(method) when method in ~w(get post put patch delete head),
    do: {:ok, String.to_existing_atom(method)}

  defp cast_method(method), do: {:error, "unsupported HTTP method #{method}"}

  defp atomize_params(params) when is_map(params) do
    for {key, value} <- params, key in ~w(temperature max_tokens top_p), into: %{} do
      {String.to_existing_atom(key), value}
    end
  end

  defp atomize_params(_params), do: %{}

  defp owned(scope, %{workspace_id: workspace_id}) do
    if workspace_id == Scope.workspace_id(scope), do: :ok, else: {:error, :not_found}
  end
end
