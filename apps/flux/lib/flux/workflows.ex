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
  alias Flux.Workflows.{Workflow, WorkflowRun, WorkflowVersion}

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

      {:ok, inserted}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_graph, errors}}
      {:error, reason} -> {:error, reason}
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

  @doc """
  Validates the graph, inserts a `:running` row, subscribes the caller to
  the run topic, and executes in a supervised task. `opts`:

    * `:source` — `:draft` (default) or `:api`
    * `:graph` — graph map to execute (defaults to the workflow's draft)
    * `:version` — version number recorded on the run
  """
  def start_run(%Scope{} = scope, %Workflow{} = workflow, inputs, opts \\ []) do
    graph_map = Keyword.get(opts, :graph, workflow.graph)

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
           latest_version(scope, workflow.id) || {:error, :not_published} do
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

  ## API tokens

  def create_api_token(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         :ok <- owned(scope, workflow) do
      raw = "flux-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      token =
        Repo.insert!(%ApiToken{
          workspace_id: workflow.workspace_id,
          workflow_id: workflow.id,
          token_hash: :crypto.hash(:sha256, raw),
          prefix: String.slice(raw, 0, 13) <> "…"
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
        token
        |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
        |> Repo.update()

        case Repo.get!(Workflow, workflow_id, skip_workspace_guard: true) do
          %Workflow{deleted_at: nil} = workflow -> {:ok, workflow, token}
          _trashed -> {:error, :invalid_token}
        end

      _other ->
        {:error, :invalid_token}
    end
  end

  def fetch_workflow_by_token(_other), do: {:error, :invalid_token}

  ## Run internals

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
    {:ok, usage_acc} = Agent.start_link(fn -> %{} end)

    host =
      workspace_id
      |> build_host(fn event ->
        Phoenix.PubSub.broadcast(Flux.PubSub, topic(run.id), {:engine_event, event})
      end)
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
              Agent.update(usage_acc, &add_model_usage(&1, request.model, usage))

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
      Enum.reduce(fresh, run.usage["by_model"] || %{}, fn {model, usage}, acc ->
        add_model_usage(acc, model, usage)
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
        "by_model" => by_model
      }

      case Flux.Pricing.cost_for(by_model) do
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

      resume = %{
        pool: snapshot["pool"] || %{},
        node_id: snapshot["node_id"],
        input: input
      }

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

    :telemetry.execute(
      [:flux, :workflow, :run, :finished],
      %{duration_ms: run.elapsed_ms || 0},
      %{status: run.status, source: run.source, workspace_id: run.workspace_id}
    )

    if run.status == :failed, do: enqueue_alert(run)

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

  defp build_host(workspace_id, emit, depth \\ 0) do
    %Host{
      emit: emit,
      invoke_llm: build_llm_invoker(workspace_id),
      invoke_tool: fn %{toolset_id: toolset_id, operation_id: operation_id, args: args} ->
        Flux.Tools.invoke_for_workspace(workspace_id, toolset_id, operation_id, args)
      end,
      http_request: &node_http_request/1,
      run_code: &Flux.CodeRunner.run/1,
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
  defp maybe_convert(_format, binary), do: {:ok, binary}

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
      _other -> "application/octet-stream"
    end
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
    fn %{dataset_ids: dataset_ids, query: query, top_k: top_k} ->
      rag = Application.get_env(:flux, :rag_module, Flux.RAG)
      scope = %Scope{workspace: %Flux.Accounts.Workspace{id: workspace_id}}

      cond do
        not Code.ensure_loaded?(rag) ->
          {:error, "knowledge retrieval is unavailable in this deployment"}

        true ->
          case rag.retrieve_many(scope, dataset_ids, query, top_k: top_k) do
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
    fn %{workflow_id: workflow_id, item: item, index: index} ->
      scope = %Scope{workspace: %Flux.Accounts.Workspace{id: workspace_id}}

      with :ok <- (depth < 1 && :ok) || {:error, "sub-fluxes cannot start their own sub-fluxes"},
           %Workflow{workspace_id: ^workspace_id, deleted_at: nil} = workflow <-
             Repo.get_by(Workflow, [id: workflow_id], skip_workspace_guard: true) ||
               {:error, "sub-flux not found"},
           %WorkflowVersion{} = version <-
             latest_version(scope, workflow.id) || {:error, "sub-flux has no published version"},
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
    workspace_id = Scope.workspace_id(scope)

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
    fn request, chunk_emit ->
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
          {:ok,
           %{
             content: result.content,
             usage: %{
               "input_tokens" => result.usage.input_tokens,
               "output_tokens" => result.usage.output_tokens
             },
             tool_calls: result.tool_calls
           }}

        {:error, reason} ->
          {:error, reason}
      end
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
