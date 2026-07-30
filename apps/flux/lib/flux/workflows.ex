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
    Workflow |> Repo.scoped(scope) |> order_by([w], desc: w.updated_at) |> Repo.all()
  end

  def get_workflow(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Workflow, id: ^id), scope)) || {:error, :not_found}
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

  def delete_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         :ok <- owned(scope, workflow) do
      Repo.delete(workflow)
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

      {:ok, Repo.insert!(version)}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_graph, errors}}
      {:error, reason} -> {:error, reason}
    end
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

        {:ok, _pid} =
          Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
            Registry.register(Flux.GenerationRegistry, run.id, nil)
            execute(run, graph, inputs, workspace_id)
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

      {:ok, token, raw}
    end
  end

  def list_api_tokens(%Scope{} = scope, workflow_id) do
    ApiToken |> Repo.scoped(scope) |> where([t], t.workflow_id == ^workflow_id) |> Repo.all()
  end

  def revoke_api_token(%Scope{} = scope, token_id) do
    case Repo.one(Repo.scoped(where(ApiToken, id: ^token_id), scope)) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
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

        {:ok, Repo.get!(Workflow, workflow_id, skip_workspace_guard: true), token}

      _other ->
        {:error, :invalid_token}
    end
  end

  def fetch_workflow_by_token(_other), do: {:error, :invalid_token}

  ## Run internals

  defp execute(run, graph, inputs, workspace_id) do
    host = %Host{
      emit: fn event ->
        Phoenix.PubSub.broadcast(Flux.PubSub, topic(run.id), {:engine_event, event})
      end,
      invoke_llm: build_llm_invoker(workspace_id),
      invoke_tool: fn %{toolset_id: toolset_id, operation_id: operation_id, args: args} ->
        Flux.Tools.invoke_for_workspace(workspace_id, toolset_id, operation_id, args)
      end
    }

    case Engine.run(graph, inputs, host) do
      {:ok, result} ->
        finalize(run, %{
          status: :succeeded,
          outputs: result.outputs,
          node_executions: result.node_executions,
          elapsed_ms: result.elapsed_ms
        })

      {:error, failure} ->
        finalize(run, %{
          status: :failed,
          error: failure.error,
          node_executions: failure.node_executions,
          elapsed_ms: failure.elapsed_ms
        })
    end
  end

  defp finalize(run, changes) do
    run = run |> Ecto.Changeset.change(changes) |> Repo.update!()
    Phoenix.PubSub.broadcast(Flux.PubSub, topic(run.id), {:run_finished, run})
    {:ok, run}
  end

  defp build_llm_invoker(workspace_id) do
    fn request, chunk_emit ->
      credentials =
        case Providers.fetch_config(workspace_id, request.provider_plugin_id) do
          {:ok, config} -> config
          {:error, :not_configured} -> %{}
        end

      provider_request = %Flux.Plugin.ModelProvider.Request{
        model: request.model,
        messages: request.messages,
        params: atomize_params(request.params)
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
             }
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

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
