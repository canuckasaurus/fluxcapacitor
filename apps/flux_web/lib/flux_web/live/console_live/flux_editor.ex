defmodule FluxWeb.ConsoleLive.FluxEditor do
  @moduledoc """
  The Flux canvas: a LiveView-native workflow editor.

  Nodes are absolutely-positioned divs over an SVG edge layer; a colocated
  JS hook handles node dragging and port-to-port edge creation, pushing
  `node_moved` / `connect` events. All graph state lives server-side and
  every mutation auto-saves the draft.
  """
  use FluxWeb, :live_view

  alias Flux.Engine
  alias Flux.Providers
  alias Flux.RBAC
  alias Flux.Workflows

  @node_width 208
  @port_y 28
  @false_port_y 56

  @node_meta %{
    "start" => %{label: "Start", icon: "hero-play", accent: "bg-primary/10 text-primary"},
    "llm" => %{label: "LLM", icon: "hero-sparkles", accent: "bg-secondary/10 text-secondary"},
    "if_else" => %{
      label: "If / Else",
      icon: "hero-arrows-right-left",
      accent: "bg-warning/10 text-warning"
    },
    "template" => %{
      label: "Template",
      icon: "hero-code-bracket",
      accent: "bg-accent/10 text-accent"
    },
    "answer" => %{
      label: "Answer",
      icon: "hero-chat-bubble-bottom-center-text",
      accent: "bg-success/10 text-success"
    },
    "end" => %{label: "End", icon: "hero-flag", accent: "bg-base-300 text-base-content"},
    "tool" => %{
      label: "Tool",
      icon: "hero-wrench-screwdriver",
      accent: "bg-info/10 text-info"
    },
    "http_request" => %{
      label: "HTTP Request",
      icon: "hero-globe-alt",
      accent: "bg-info/10 text-info"
    },
    "code" => %{
      label: "Code",
      icon: "hero-command-line",
      accent: "bg-neutral/10 text-neutral"
    },
    "agent" => %{
      label: "Agent",
      icon: "hero-cpu-chip",
      accent: "bg-secondary/10 text-secondary"
    },
    "variable_aggregator" => %{
      label: "Aggregator",
      icon: "hero-funnel",
      accent: "bg-accent/10 text-accent"
    },
    "variable_assigner" => %{
      label: "Assigner",
      icon: "hero-pencil-square",
      accent: "bg-accent/10 text-accent"
    },
    "list_operator" => %{
      label: "List Operator",
      icon: "hero-list-bullet",
      accent: "bg-info/10 text-info"
    },
    "question_classifier" => %{
      label: "Classifier",
      icon: "hero-arrows-pointing-out",
      accent: "bg-warning/10 text-warning"
    },
    "parameter_extractor" => %{
      label: "Extractor",
      icon: "hero-magnifying-glass",
      accent: "bg-secondary/10 text-secondary"
    }
  }

  @addable_types ~w(llm if_else question_classifier parameter_extractor template tool
                    http_request code agent variable_aggregator variable_assigner
                    list_operator answer end)
  @zoom_levels [50, 65, 80, 100, 125, 150]
  @failable_types ~w(llm tool http_request code agent question_classifier parameter_extractor)
  @history_cap 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow(scope, id) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Flux not found.")
         |> push_navigate(to: ~p"/console/fluxes")}

      workflow ->
        {:ok,
         socket
         |> assign(
           page_title: workflow.name,
           workflow: workflow,
           graph: workflow.graph,
           selected_id: nil,
           selected_ids: [],
           selected_edge: nil,
           issues: issues(workflow.graph),
           models: Providers.available_models(scope),
           toolsets: Flux.Tools.list_toolsets(scope),
           latest_version: Workflows.latest_version(scope, workflow.id),
           can_edit: RBAC.can?(scope, :app_edit),
           can_export: RBAC.can?(scope, :app_import_export_dsl),
           can_run: RBAC.can?(scope, :app_test_and_run),
           can_publish: RBAC.can?(scope, :app_release_and_version),
           can_manage_tokens: RBAC.can?(scope, :app_create_and_management),
           show_run: false,
           run: nil,
           node_states: %{},
           run_text: "",
           show_api: false,
           tokens: [],
           new_token_raw: nil,
           show_triggers: false,
           triggers: [],
           trigger_type: "webhook",
           show_site: false,
           zoom: 100,
           undo_stack: [],
           redo_stack: [],
           show_history: false,
           runs: [],
           selected_run_id: nil
         )}
    end
  end

  ## Graph mutations (all auto-save the draft)

  @impl true
  def handle_event("node_moved", %{"id" => id, "x" => x, "y" => y}, socket) do
    update_graph(socket, fn graph ->
      update_node_in(graph, id, fn node ->
        Map.put(node, "position", %{"x" => max(round_num(x), 0), "y" => max(round_num(y), 0)})
      end)
    end)
  end

  def handle_event(
        "connect",
        %{"source" => source, "source_handle" => handle, "target" => target},
        socket
      ) do
    target_node = find_node(socket.assigns.graph, target)

    if source == target or is_nil(target_node) or target_node["type"] == "start" do
      {:noreply, socket}
    else
      update_graph(socket, fn graph ->
        edges =
          graph
          |> Map.get("edges", [])
          |> Enum.reject(&(&1["source"] == source and &1["source_handle"] == handle))

        edge = %{
          "id" => "edge_#{source}_#{handle}_#{target}",
          "source" => source,
          "source_handle" => handle,
          "target" => target
        }

        Map.put(graph, "edges", edges ++ [edge])
      end)
    end
  end

  def handle_event("add_node", %{"type" => type}, socket) when type in @addable_types do
    graph = socket.assigns.graph
    id = unique_node_id(graph, type)
    count = length(graph["nodes"] || [])

    node = %{
      "id" => id,
      "type" => type,
      "title" => @node_meta[type].label,
      "position" => %{"x" => 160 + rem(count, 4) * 70, "y" => 60 + rem(count, 6) * 70},
      "config" => default_config(type)
    }

    socket = set_selection(socket, [id])
    update_graph(socket, fn graph -> Map.update(graph, "nodes", [node], &(&1 ++ [node])) end)
  end

  def handle_event("select_node", %{"id" => id} = params, socket) do
    shift = params["shift"] in [true, "true"]
    ids = socket.assigns.selected_ids

    ids =
      cond do
        shift and id in ids -> List.delete(ids, id)
        shift -> ids ++ [id]
        true -> [id]
      end

    {:noreply, set_selection(socket, ids)}
  end

  def handle_event("select_edge", %{"id" => id}, socket) do
    {:noreply, set_selection(socket, [], id)}
  end

  def handle_event("marquee_select", %{"ids" => ids}, socket) when is_list(ids) do
    valid = Enum.filter(ids, &find_node(socket.assigns.graph, &1))
    {:noreply, set_selection(socket, valid)}
  end

  def handle_event("deselect", _params, socket) do
    {:noreply, set_selection(socket, [])}
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    case find_node(socket.assigns.graph, id) do
      %{"type" => "start"} ->
        {:noreply, put_flash(socket, :error, "The start node can't be deleted.")}

      _node ->
        socket = set_selection(socket, [])

        update_graph(socket, fn graph ->
          graph
          |> Map.update("nodes", [], fn nodes -> Enum.reject(nodes, &(&1["id"] == id)) end)
          |> Map.update("edges", [], fn edges ->
            Enum.reject(edges, &(&1["source"] == id or &1["target"] == id))
          end)
        end)
    end
  end

  def handle_event("delete_edge", %{"id" => id}, socket) do
    update_graph(socket, fn graph ->
      Map.update(graph, "edges", [], fn edges -> Enum.reject(edges, &(&1["id"] == id)) end)
    end)
  end

  # Batch position update after a (possibly multi-node) drag: one draft
  # save, so undo restores every node in a single step.
  def handle_event("nodes_moved", %{"moves" => moves}, socket) when is_list(moves) do
    update_graph(socket, fn graph ->
      Enum.reduce(moves, graph, fn
        %{"id" => id, "x" => x, "y" => y}, graph ->
          update_node_in(graph, id, fn node ->
            Map.put(node, "position", %{
              "x" => max(round_num(x), 0),
              "y" => max(round_num(y), 0)
            })
          end)

        _malformed, graph ->
          graph
      end)
    end)
  end

  # Delete/Backspace pressed on the canvas (never from inside a form field):
  # removes the selected edge, or every selected node except start.
  def handle_event("delete_selection", _params, socket) do
    cond do
      socket.assigns.selected_edge != nil ->
        edge_id = socket.assigns.selected_edge
        handle_event("delete_edge", %{"id" => edge_id}, set_selection(socket, []))

      socket.assigns.selected_ids != [] ->
        ids =
          Enum.reject(socket.assigns.selected_ids, fn id ->
            match?(%{"type" => "start"}, find_node(socket.assigns.graph, id))
          end)

        if ids == [] do
          {:noreply, put_flash(socket, :error, "The start node can't be deleted.")}
        else
          socket = set_selection(socket, [])
          update_graph(socket, &drop_nodes(&1, ids))
        end

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("duplicate_node", %{"id" => id}, socket) do
    case find_node(socket.assigns.graph, id) do
      %{"type" => type} = node when type != "start" ->
        new_id = unique_node_id(socket.assigns.graph, type)

        copy =
          node
          |> Map.put("id", new_id)
          |> Map.put("position", %{
            "x" => node_x(node) + 40,
            "y" => node_y(node) + 40
          })

        socket = set_selection(socket, [new_id])
        update_graph(socket, fn graph -> Map.update(graph, "nodes", [copy], &(&1 ++ [copy])) end)

      _start_or_missing ->
        {:noreply, socket}
    end
  end

  def handle_event("undo", _params, socket) do
    case socket.assigns.undo_stack do
      [] ->
        {:noreply, socket}

      [previous | rest] ->
        current = socket.assigns.graph

        case persist_graph(socket, previous) do
          {:ok, socket} ->
            {:noreply,
             assign(socket,
               undo_stack: rest,
               redo_stack: [current | socket.assigns.redo_stack]
             )}

          {:error, socket} ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("redo", _params, socket) do
    case socket.assigns.redo_stack do
      [] ->
        {:noreply, socket}

      [next | rest] ->
        current = socket.assigns.graph

        case persist_graph(socket, next) do
          {:ok, socket} ->
            {:noreply,
             assign(socket,
               redo_stack: rest,
               undo_stack: [current | socket.assigns.undo_stack]
             )}

          {:error, socket} ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("zoom", %{"dir" => dir}, socket) do
    index = Enum.find_index(@zoom_levels, &(&1 == socket.assigns.zoom)) || 3

    zoom =
      case dir do
        "in" -> Enum.at(@zoom_levels, min(index + 1, length(@zoom_levels) - 1))
        "out" -> Enum.at(@zoom_levels, max(index - 1, 0))
        _reset -> 100
      end

    {:noreply, assign(socket, zoom: zoom)}
  end

  # Fired by both the name input's phx-blur (%{"value" => _}) and the
  # surrounding form's phx-submit (%{"name" => _}).
  def handle_event("rename", params, socket) do
    name = String.trim(params["name"] || params["value"] || "")
    workflow = socket.assigns.workflow

    if socket.assigns.can_edit and name != "" and name != workflow.name do
      case Workflows.update_workflow(socket.assigns.current_scope, workflow, %{"name" => name}) do
        {:ok, workflow} ->
          {:noreply, assign(socket, workflow: workflow, page_title: workflow.name)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not rename the flux.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_history", _params, socket) do
    show = not socket.assigns.show_history

    runs =
      if show do
        Workflows.list_runs(socket.assigns.current_scope, socket.assigns.workflow.id)
      else
        []
      end

    {:noreply, assign(socket, show_history: show, runs: runs, selected_run_id: nil)}
  end

  def handle_event("select_run", %{"id" => id}, socket) do
    selected = if socket.assigns.selected_run_id == id, do: nil, else: id
    {:noreply, assign(socket, selected_run_id: selected)}
  end

  def handle_event("update_node", params, socket) do
    case selected_node(socket) do
      nil ->
        {:noreply, socket}

      node ->
        params = Map.put(params, "__toolsets__", socket.assigns.toolsets)

        update_graph(socket, fn graph ->
          update_node_in(graph, node["id"], fn current ->
            config =
              current["type"]
              |> build_config(current["config"], params)
              |> put_retry(params)

            current
            |> Map.put("title", Map.get(params, "title", current["title"]))
            |> Map.put("config", config)
          end)
        end)
    end
  end

  # Retry settings apply to every failable node type, so they merge in
  # after the type-specific config is built.
  defp put_retry(config, %{"max_retries" => max_retries}) do
    case Integer.parse(to_string(max_retries)) do
      {n, ""} when n > 0 -> Map.put(config, "retry", %{"max_retries" => min(n, 5)})
      _off -> Map.delete(config, "retry")
    end
  end

  defp put_retry(config, _params), do: config

  def handle_event("add_row", %{"kind" => kind}, socket) do
    update_selected_rows(socket, kind, &(&1 ++ [empty_row(kind)]))
  end

  def handle_event("remove_row", %{"kind" => kind, "index" => index}, socket) do
    index = String.to_integer(index)
    update_selected_rows(socket, kind, &List.delete_at(&1, index))
  end

  ## Run / publish / API

  def handle_event("open_run", _params, socket) do
    {:noreply, assign(socket, show_run: true)}
  end

  def handle_event("close_run", _params, socket) do
    {:noreply, assign(socket, show_run: false, node_states: %{}, run: nil, run_text: "")}
  end

  def handle_event("start_run", params, socket) do
    if socket.assigns.can_run do
      scope = socket.assigns.current_scope
      inputs = Map.get(params, "inputs", %{})

      case Workflows.start_run(scope, socket.assigns.workflow, inputs) do
        {:ok, run} ->
          {:noreply, assign(socket, run: run, node_states: %{}, run_text: "")}

        {:error, {:invalid_graph, errors}} ->
          {:noreply, put_flash(socket, :error, "Fix the graph first: #{Enum.join(errors, "; ")}")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to run fluxes.")}
    end
  end

  def handle_event("stop_run", _params, socket) do
    case socket.assigns.run do
      %{id: run_id} -> Workflows.stop_run(socket.assigns.current_scope, run_id)
      _no_run -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("publish", _params, socket) do
    scope = socket.assigns.current_scope

    case Workflows.publish(scope, socket.assigns.workflow) do
      {:ok, version} ->
        {:noreply,
         socket
         |> assign(latest_version: version)
         |> put_flash(:info, "Published v#{version.version}.")}

      {:error, {:invalid_graph, errors}} ->
        {:noreply, put_flash(socket, :error, "Fix the graph first: #{Enum.join(errors, "; ")}")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to publish.")}
    end
  end

  def handle_event("toggle_api", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     assign(socket,
       show_api: not socket.assigns.show_api,
       new_token_raw: nil,
       tokens: Workflows.list_api_tokens(scope, socket.assigns.workflow.id)
     )}
  end

  def handle_event("create_token", _params, socket) do
    scope = socket.assigns.current_scope

    case Workflows.create_api_token(scope, socket.assigns.workflow) do
      {:ok, _token, raw} ->
        {:noreply,
         assign(socket,
           new_token_raw: raw,
           tokens: Workflows.list_api_tokens(scope, socket.assigns.workflow.id)
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage API keys.")}
    end
  end

  def handle_event("revoke_token", %{"token-id" => token_id}, socket) do
    scope = socket.assigns.current_scope
    Workflows.revoke_api_token(scope, token_id)

    {:noreply,
     assign(socket, tokens: Workflows.list_api_tokens(scope, socket.assigns.workflow.id))}
  end

  ## Site publishing

  def handle_event("toggle_site", _params, socket) do
    {:noreply, assign(socket, show_site: not socket.assigns.show_site)}
  end

  def handle_event("enable_site", _params, socket) do
    case Workflows.enable_site(socket.assigns.current_scope, socket.assigns.workflow) do
      {:ok, workflow} ->
        {:noreply, assign(socket, workflow: workflow)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to publish this flux.")}
    end
  end

  def handle_event("disable_site", _params, socket) do
    case Workflows.disable_site(socket.assigns.current_scope, socket.assigns.workflow) do
      {:ok, workflow} ->
        {:noreply, assign(socket, workflow: workflow)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to unpublish this flux.")}
    end
  end

  ## Triggers

  def handle_event("toggle_triggers", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     assign(socket,
       show_triggers: not socket.assigns.show_triggers,
       trigger_type: "webhook",
       triggers: Workflows.list_triggers(scope, socket.assigns.workflow.id)
     )}
  end

  def handle_event("trigger_form_change", %{"type" => type}, socket) do
    {:noreply, assign(socket, trigger_type: type)}
  end

  def handle_event("create_trigger", params, socket) do
    scope = socket.assigns.current_scope

    with {:ok, inputs} <- parse_trigger_inputs(params["inputs"]),
         {:ok, _trigger} <-
           Workflows.create_trigger(scope, socket.assigns.workflow, %{
             "type" => params["type"],
             "interval_minutes" => params["interval_minutes"],
             "inputs" => inputs
           }) do
      {:noreply,
       assign(socket, triggers: Workflows.list_triggers(scope, socket.assigns.workflow.id))}
    else
      {:error, :bad_json} ->
        {:noreply, put_flash(socket, :error, "Static inputs must be a JSON object.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage triggers.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error(changeset))}
    end
  end

  def handle_event("toggle_trigger", %{"trigger-id" => trigger_id, "enabled" => enabled}, socket) do
    scope = socket.assigns.current_scope
    Workflows.set_trigger_enabled(scope, trigger_id, enabled == "true")

    {:noreply,
     assign(socket, triggers: Workflows.list_triggers(scope, socket.assigns.workflow.id))}
  end

  def handle_event("delete_trigger", %{"trigger-id" => trigger_id}, socket) do
    scope = socket.assigns.current_scope
    Workflows.delete_trigger(scope, trigger_id)

    {:noreply,
     assign(socket, triggers: Workflows.list_triggers(scope, socket.assigns.workflow.id))}
  end

  ## Engine events

  @impl true
  def handle_info({:engine_event, {:node_started, %{node_id: id}}}, socket) do
    {:noreply, assign(socket, node_states: Map.put(socket.assigns.node_states, id, :running))}
  end

  def handle_info({:engine_event, {:node_finished, %{node_id: id}}}, socket) do
    {:noreply, assign(socket, node_states: Map.put(socket.assigns.node_states, id, :done))}
  end

  def handle_info({:engine_event, {:node_failed, %{node_id: id}}}, socket) do
    {:noreply, assign(socket, node_states: Map.put(socket.assigns.node_states, id, :error))}
  end

  def handle_info({:engine_event, {:node_chunk, %{delta: delta}}}, socket) do
    {:noreply, assign(socket, run_text: socket.assigns.run_text <> delta)}
  end

  def handle_info({:engine_event, _event}, socket), do: {:noreply, socket}

  def handle_info({:run_finished, run}, socket) do
    socket = assign(socket, run: run)

    if socket.assigns.show_history do
      {:noreply,
       assign(socket,
         runs: Workflows.list_runs(socket.assigns.current_scope, socket.assigns.workflow.id)
       )}
    else
      {:noreply, socket}
    end
  end

  ## Graph helpers

  defp update_graph(socket, fun) do
    previous = socket.assigns.graph

    case persist_graph(socket, fun.(previous)) do
      {:ok, socket} ->
        {:noreply,
         assign(socket,
           undo_stack: Enum.take([previous | socket.assigns.undo_stack], @history_cap),
           redo_stack: []
         )}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  defp persist_graph(socket, graph) do
    with true <- socket.assigns.can_edit,
         {:ok, workflow} <-
           Workflows.update_draft(socket.assigns.current_scope, socket.assigns.workflow, graph) do
      {:ok,
       assign(socket, workflow: workflow, graph: workflow.graph, issues: issues(workflow.graph))}
    else
      false -> {:error, socket}
      {:error, _reason} -> {:error, put_flash(socket, :error, "Could not save the change.")}
    end
  end

  defp issues(graph) do
    case Engine.build(graph) do
      {:ok, _graph} -> []
      {:error, errors} -> errors
    end
  end

  defp drop_nodes(graph, ids) do
    graph
    |> Map.update("nodes", [], fn nodes -> Enum.reject(nodes, &(&1["id"] in ids)) end)
    |> Map.update("edges", [], fn edges ->
      Enum.reject(edges, &(&1["source"] in ids or &1["target"] in ids))
    end)
  end

  # `selected_id` stays derived (the single selection, or nil) so the config
  # panel and its guards keep working untouched.
  defp set_selection(socket, ids, edge \\ nil) do
    assign(socket,
      selected_ids: ids,
      selected_id: (match?([_single], ids) && hd(ids)) || nil,
      selected_edge: edge
    )
  end

  defp find_node(graph, id), do: Enum.find(graph["nodes"] || [], &(&1["id"] == id))

  defp selected_node(socket), do: find_node(socket.assigns.graph, socket.assigns.selected_id)

  defp update_selected_rows(socket, kind, fun) do
    case selected_node(socket) do
      nil ->
        {:noreply, socket}

      node ->
        update_graph(socket, fn graph ->
          update_node_in(graph, node["id"], &update_config_rows(&1, row_key(kind), fun))
        end)
    end
  end

  defp update_config_rows(node, key, fun) do
    update_in(node, ["config", key], fn rows -> fun.(List.wrap(rows)) end)
  end

  defp update_node_in(graph, id, fun) do
    Map.update(graph, "nodes", [], fn nodes ->
      Enum.map(nodes, fn
        %{"id" => ^id} = node -> fun.(node)
        node -> node
      end)
    end)
  end

  defp unique_node_id(graph, type) do
    existing = MapSet.new(graph["nodes"] || [], & &1["id"])

    Enum.find(Stream.map(1..1_000, &"#{type}_#{&1}"), &(not MapSet.member?(existing, &1)))
  end

  defp default_config("llm"),
    do: %{"provider_plugin_id" => "", "model" => "", "system_prompt" => "", "prompt" => ""}

  defp default_config("if_else"),
    do: %{
      "logical_operator" => "and",
      "conditions" => [%{"left" => "", "operator" => "contains", "right" => ""}]
    }

  defp default_config("template"), do: %{"template" => ""}

  defp default_config("tool"),
    do: %{"toolset_id" => "", "operation_id" => "", "args" => %{}}

  defp default_config("http_request"),
    do: %{"method" => "get", "url" => "", "headers" => [], "body" => ""}

  defp default_config("agent") do
    %{
      "provider_plugin_id" => "",
      "model" => "",
      "instructions" => "",
      "query" => "{{start.query}}",
      "max_iterations" => 5,
      "agent_toolset_id" => "",
      "tools" => []
    }
  end

  defp default_config("code") do
    %{
      "language" => "python3",
      "code" => "def main(query: str) -> dict:\n    return {\"result\": query.upper()}",
      "dependencies" => [],
      "inputs" => [%{"name" => "query", "value" => "{{start.query}}"}],
      "timeout_ms" => 30_000
    }
  end

  defp default_config("answer"), do: %{"answer" => ""}
  defp default_config("end"), do: %{"outputs" => [%{"key" => "result", "value" => ""}]}

  defp default_config("question_classifier") do
    %{
      "provider_plugin_id" => "",
      "model" => "",
      "query" => "{{start.query}}",
      "instruction" => "",
      "classes" => [
        %{"id" => "class_1", "name" => ""},
        %{"id" => "class_2", "name" => ""}
      ]
    }
  end

  defp default_config("parameter_extractor") do
    %{
      "provider_plugin_id" => "",
      "model" => "",
      "query" => "{{start.query}}",
      "instruction" => "",
      "parameters" => [
        %{"name" => "", "type" => "string", "description" => "", "required" => false}
      ]
    }
  end

  defp default_config("variable_aggregator"), do: %{"variables" => []}

  defp default_config("variable_assigner"),
    do: %{"assignments" => [%{"name" => "", "value" => ""}]}

  defp default_config("list_operator"),
    do: %{
      "variable" => "",
      "filter" => %{"operator" => "", "value" => ""},
      "sort" => "none",
      "limit" => ""
    }

  defp default_config(_type), do: %{}

  defp row_key("variable"), do: "variables"
  defp row_key("header"), do: "headers"
  defp row_key("dependency"), do: "dependencies"
  defp row_key("code_input"), do: "inputs"
  defp row_key("condition"), do: "conditions"
  defp row_key("output"), do: "outputs"
  defp row_key("assignment"), do: "assignments"
  defp row_key("class"), do: "classes"
  defp row_key("parameter"), do: "parameters"

  defp empty_row("variable"),
    do: %{"name" => "", "label" => "", "type" => "text", "required" => false}

  defp empty_row("header"), do: %{"key" => "", "value" => ""}
  defp empty_row("dependency"), do: %{"name" => "", "version" => ""}
  defp empty_row("code_input"), do: %{"name" => "", "value" => ""}
  defp empty_row("condition"), do: %{"left" => "", "operator" => "contains", "right" => ""}
  defp empty_row("output"), do: %{"key" => "", "value" => ""}
  defp empty_row("assignment"), do: %{"name" => "", "value" => ""}
  defp empty_row("class"), do: %{"id" => "", "name" => ""}

  defp empty_row("parameter"),
    do: %{"name" => "", "type" => "string", "description" => "", "required" => false}

  defp build_config("llm", config, params) do
    {plugin_id, model} =
      case String.split(Map.get(params, "model_choice", ""), "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _other -> {config["provider_plugin_id"], config["model"]}
      end

    %{
      "provider_plugin_id" => plugin_id,
      "model" => model,
      "system_prompt" => Map.get(params, "system_prompt", ""),
      "prompt" => Map.get(params, "prompt", "")
    }
  end

  defp build_config("start", config, params) do
    Map.put(
      config,
      "variables",
      indexed_rows(params["vars"], ~w(name label type), %{"required" => true})
    )
  end

  defp build_config("if_else", config, params) do
    config
    |> Map.put("logical_operator", Map.get(params, "logical_operator", "and"))
    |> Map.put("conditions", indexed_rows(params["conds"], ~w(left operator right), %{}))
  end

  defp build_config("template", config, params) do
    Map.put(config, "template", Map.get(params, "template", ""))
  end

  defp build_config("http_request", config, params) do
    config
    |> Map.put("method", Map.get(params, "method", config["method"] || "get"))
    |> Map.put("url", Map.get(params, "url", ""))
    |> Map.put("body", Map.get(params, "body", ""))
    |> Map.put("headers", indexed_rows(params["hdrs"], ~w(key value), %{}))
  end

  defp build_config("code", config, params) do
    config
    |> Map.put("language", Map.get(params, "language", config["language"] || "python3"))
    |> Map.put("code", Map.get(params, "code", config["code"] || ""))
    |> Map.put("dependencies", indexed_rows(params["deps"], ~w(name version), %{}))
    |> Map.put("inputs", indexed_rows(params["cins"], ~w(name value), %{}))
  end

  defp build_config("agent", config, params) do
    {plugin_id, model} =
      case String.split(Map.get(params, "model_choice", ""), "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _other -> {config["provider_plugin_id"], config["model"]}
      end

    toolset_id = Map.get(params, "agent_toolset_id", config["agent_toolset_id"] || "")

    %{
      "provider_plugin_id" => plugin_id,
      "model" => model,
      "instructions" => Map.get(params, "instructions", config["instructions"] || ""),
      "query" => Map.get(params, "query", config["query"] || ""),
      "max_iterations" => parse_iterations(Map.get(params, "max_iterations")),
      "output_schema" => parse_output_schema(params["output_schema"], config["output_schema"]),
      "agent_toolset_id" => toolset_id,
      "tools" =>
        if toolset_id == config["agent_toolset_id"] do
          config["tools"] || []
        else
          snapshot_tools(toolset_id, Map.get(params, "__toolsets__", []))
        end
    }
  end

  defp build_config("tool", config, params) do
    toolset_id = Map.get(params, "toolset_id", config["toolset_id"] || "")
    operation_id = Map.get(params, "operation_id", config["operation_id"] || "")

    # Changing the toolset or operation resets the argument mapping.
    args =
      cond do
        toolset_id != config["toolset_id"] -> %{}
        operation_id != config["operation_id"] -> %{}
        true -> stringify_map(params["args"] || config["args"] || %{})
      end

    %{"toolset_id" => toolset_id, "operation_id" => operation_id, "args" => args}
  end

  defp build_config("question_classifier", config, params) do
    {plugin_id, model} =
      case String.split(Map.get(params, "model_choice", ""), "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _other -> {config["provider_plugin_id"], config["model"]}
      end

    config
    |> Map.put("provider_plugin_id", plugin_id)
    |> Map.put("model", model)
    |> Map.put("query", Map.get(params, "query", config["query"] || ""))
    |> Map.put("instruction", Map.get(params, "instruction", config["instruction"] || ""))
    |> Map.put("classes", indexed_rows(params["cls"], ~w(id name), %{}))
  end

  defp build_config("parameter_extractor", config, params) do
    {plugin_id, model} =
      case String.split(Map.get(params, "model_choice", ""), "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _other -> {config["provider_plugin_id"], config["model"]}
      end

    config
    |> Map.put("provider_plugin_id", plugin_id)
    |> Map.put("model", model)
    |> Map.put("query", Map.get(params, "query", config["query"] || ""))
    |> Map.put("instruction", Map.get(params, "instruction", config["instruction"] || ""))
    |> Map.put(
      "parameters",
      indexed_rows(params["prms"], ~w(name type description), %{"required" => false})
    )
  end

  defp build_config("variable_aggregator", config, params) do
    variables =
      params
      |> Map.get("variables_text", "")
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(config, "variables", variables)
  end

  defp build_config("variable_assigner", config, params) do
    Map.put(config, "assignments", indexed_rows(params["asgn"], ~w(name value), %{}))
  end

  defp build_config("list_operator", config, params) do
    config
    |> Map.put("variable", Map.get(params, "variable", ""))
    |> Map.put("filter", %{
      "operator" => Map.get(params, "filter_operator", ""),
      "value" => Map.get(params, "filter_value", "")
    })
    |> Map.put("sort", Map.get(params, "sort", "none"))
    |> Map.put("limit", Map.get(params, "limit", ""))
  end

  defp build_config("answer", config, params) do
    Map.put(config, "answer", Map.get(params, "answer", ""))
  end

  defp build_config("end", config, params) do
    Map.put(config, "outputs", indexed_rows(params["outs"], ~w(key value), %{}))
  end

  defp build_config(_type, config, _params), do: config

  # Rebuilds a config row list from "0"/"1"-indexed form params, keeping
  # string fields and coercing the checkbox keys named in `booleans`.
  defp indexed_rows(nil, _fields, _booleans), do: []

  defp indexed_rows(rows, fields, booleans) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} ->
      base = Map.new(fields, fn field -> {field, to_string(Map.get(row, field, ""))} end)

      Enum.reduce(booleans, base, fn {key, _true_value}, acc ->
        Map.put(acc, key, Map.get(row, key) == "true")
      end)
    end)
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp stringify_map(_other), do: %{}

  defp parse_iterations(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in 1..25 -> parsed
      _invalid -> 5
    end
  end

  defp parse_iterations(_value), do: 5

  # Blank clears the schema; invalid JSON keeps the previous value.
  defp parse_output_schema(nil, previous), do: previous
  defp parse_output_schema("", _previous), do: nil

  defp parse_output_schema(json, previous) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = schema} -> schema
      _invalid -> previous
    end
  end

  # Snapshots every operation of the chosen toolset as an agent tool
  # (name/description/JSON-schema parameters + invocation binding). The
  # toolset comes from the workspace-scoped assigns, never a raw id lookup.
  defp snapshot_tools("", _toolsets), do: []

  defp snapshot_tools(toolset_id, toolsets) do
    case Enum.find(toolsets, &(&1.id == toolset_id)) do
      nil ->
        []

      toolset ->
        for operation <- toolset.operations do
          properties =
            Map.new(operation["params"], fn param ->
              {param["name"],
               %{
                 "type" => schema_type(param["type"]),
                 "description" => param["description"] || param["in"]
               }}
            end)

          required =
            for param <- operation["params"], param["required"], do: param["name"]

          %{
            "name" => operation["operation_id"],
            "description" =>
              "#{String.upcase(operation["method"])} #{operation["path"]} — #{operation["summary"]}",
            "parameters" => %{
              "type" => "object",
              "properties" => properties,
              "required" => required
            },
            "toolset_id" => toolset.id,
            "operation_id" => operation["operation_id"]
          }
        end
    end
  end

  defp schema_type(type) when type in ~w(integer number boolean string), do: type
  defp schema_type(_other), do: "string"

  defp round_num(value) when is_number(value), do: round(value)
  defp round_num(_value), do: 0

  ## Render helpers

  defp meta(type), do: Map.get(@node_meta, type, @node_meta["end"])

  defp node_x(node), do: round_num(get_in(node, ["position", "x"]) || 0)
  defp node_y(node), do: round_num(get_in(node, ["position", "y"]) || 0)

  defp edge_path(graph, edge) do
    with %{} = source <- find_node(graph, edge["source"]),
         %{} = target <- find_node(graph, edge["target"]) do
      y_offset = source_handle_offset(source, edge["source_handle"])
      x1 = node_x(source) + @node_width
      y1 = node_y(source) + y_offset
      x2 = node_x(target)
      y2 = node_y(target) + @port_y
      "M #{x1} #{y1} C #{x1 + 60} #{y1}, #{x2 - 60} #{y2}, #{x2} #{y2}"
    else
      _missing -> nil
    end
  end

  defp state_ring(nil), do: ""
  defp state_ring(:running), do: "ring-2 ring-info animate-pulse"
  defp state_ring(:done), do: "ring-2 ring-success"
  defp state_ring(:error), do: "ring-2 ring-error"

  defp node_summary(%{"type" => "llm"} = node) do
    case node["config"]["model"] do
      model when is_binary(model) and model != "" -> model
      _unset -> "no model selected"
    end
  end

  defp node_summary(%{"type" => "start"} = node) do
    names = node["config"]["variables"] |> List.wrap() |> Enum.map_join(", ", & &1["name"])
    if names == "", do: "no inputs", else: names
  end

  defp node_summary(%{"type" => "if_else"} = node) do
    "#{length(List.wrap(node["config"]["conditions"]))} condition(s)"
  end

  defp node_summary(%{"type" => "template"} = node), do: truncate(node["config"]["template"])

  defp node_summary(%{"type" => "http_request"} = node) do
    method = String.upcase(to_string(node["config"]["method"] || "get"))
    "#{method} #{truncate(node["config"]["url"])}"
  end

  defp node_summary(%{"type" => "code"} = node) do
    deps = length(List.wrap(node["config"]["dependencies"]))
    "#{node["config"]["language"] || "python3"} · #{deps} dep(s)"
  end

  defp node_summary(%{"type" => "agent"} = node) do
    tools = length(List.wrap(node["config"]["tools"]))
    model = node["config"]["model"]
    "#{(model != "" && model) || "no model"} · #{tools} tool(s)"
  end

  defp node_summary(%{"type" => "tool"} = node) do
    case node["config"]["operation_id"] do
      operation when is_binary(operation) and operation != "" -> operation
      _unset -> "no operation selected"
    end
  end

  defp node_summary(%{"type" => "answer"} = node), do: truncate(node["config"]["answer"])

  defp node_summary(%{"type" => "end"} = node) do
    keys = node["config"]["outputs"] |> List.wrap() |> Enum.map_join(", ", & &1["key"])
    if keys == "", do: "no outputs", else: keys
  end

  defp node_summary(_node), do: ""

  defp truncate(nil), do: ""
  defp truncate(text), do: String.slice(to_string(text), 0, 40)

  # Upstream references the panel offers as {{...}} hints.
  @hint_fields %{
    "llm" => ~w(text),
    "template" => ~w(output),
    "answer" => ~w(answer),
    "tool" => ~w(text status body),
    "http_request" => ~w(text status_code body),
    "code" => ~w(stdout),
    "agent" => ~w(text output status iterations tool_calls),
    "variable_aggregator" => ~w(output),
    "list_operator" => ~w(output first last count),
    "question_classifier" => ~w(class_id class_name),
    "parameter_extractor" => ~w(is_success reason)
  }

  defp variable_hints(graph, selected_id) do
    graph["nodes"]
    |> List.wrap()
    |> Enum.reject(&(&1["id"] == selected_id))
    |> Enum.flat_map(fn node ->
      case node["type"] do
        "start" ->
          node["config"]["variables"]
          |> List.wrap()
          |> Enum.map(&"{{#{node["id"]}.#{&1["name"]}}}")

        type ->
          for field <- Map.get(@hint_fields, type, []), do: "{{#{node["id"]}.#{field}}}"
      end
    end)
  end

  defp failable?(type), do: type in @failable_types

  defp source_handle_offset(%{"type" => "question_classifier"} = source, "error") do
    @port_y + length(List.wrap(source["config"]["classes"])) * 28 - 2
  end

  defp source_handle_offset(%{"type" => "question_classifier"} = source, handle) do
    index =
      source["config"]["classes"]
      |> List.wrap()
      |> Enum.find_index(&(&1["id"] == handle))

    @port_y + (index || 0) * 28 - 2
  end

  defp source_handle_offset(_source, "false"), do: @false_port_y
  defp source_handle_offset(_source, "error"), do: @false_port_y
  defp source_handle_offset(_source, _handle), do: @port_y

  defp start_variables(graph) do
    case Enum.find(graph["nodes"] || [], &(&1["type"] == "start")) do
      nil -> []
      start -> List.wrap(start["config"]["variables"])
    end
  end

  defp operators, do: Flux.Engine.Nodes.IfElse.operators()

  defp operations_for(toolsets, toolset_id) do
    case Enum.find(toolsets, &(&1.id == toolset_id)) do
      nil -> []
      toolset -> toolset.operations
    end
  end

  defp selected_operation(toolsets, config) do
    toolsets
    |> operations_for(config["toolset_id"])
    |> Enum.find(&(&1["operation_id"] == config["operation_id"]))
  end

  defp api_snippet do
    """
    POST /v1/workflows/run
    Authorization: Bearer flux-…
    {"inputs": {"query": "…"}, "response_mode": "streaming"}\
    """
  end

  defp flux_embed_snippet(workflow) do
    ~s(<iframe src="#{url(~p"/site/flux/#{workflow.site_token}")}"\n  style="width: 100%; height: 640px; border: 0; border-radius: 12px;"\n  allow="clipboard-write"></iframe>)
  end

  defp flux_bubble_snippet(workflow) do
    ~s(<script src="#{url(~p"/embed.js")}"\n  data-flux-site="#{url(~p"/site/flux/#{workflow.site_token}")}" defer></script>)
  end

  defp parse_trigger_inputs(raw) when raw in [nil, ""], do: {:ok, %{}}

  defp parse_trigger_inputs(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = inputs} -> {:ok, inputs}
      _not_an_object -> {:error, :bad_json}
    end
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:fluxes}
      full_bleed
    >
      <div class="flex flex-col gap-3 h-[calc(100vh-4rem)] min-h-[30rem]">
        <div class="flex items-center gap-3 flex-wrap">
          <.link navigate={~p"/console/fluxes"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <form phx-submit="rename" class="min-w-0">
            <input
              type="text"
              name="name"
              value={@workflow.name}
              phx-blur="rename"
              class="input input-ghost input-sm text-lg font-bold px-1 max-w-56"
              disabled={not @can_edit}
              title="Rename this flux"
            />
          </form>
          <span :if={@latest_version} class="badge badge-success badge-sm">
            v{@latest_version.version}
          </span>
          <span
            :if={@issues != []}
            class="badge badge-warning badge-sm"
            title={Enum.join(@issues, "\n")}
          >
            {length(@issues)} issue(s)
          </span>
          <div class="ml-auto flex items-center gap-2">
            <div :if={@can_edit} class="join">
              <button
                class="btn btn-sm btn-ghost join-item"
                phx-click="undo"
                disabled={@undo_stack == []}
                title="Undo (Ctrl+Z)"
              >
                <.icon name="hero-arrow-uturn-left" class="size-4" />
              </button>
              <button
                class="btn btn-sm btn-ghost join-item"
                phx-click="redo"
                disabled={@redo_stack == []}
                title="Redo (Ctrl+Shift+Z)"
              >
                <.icon name="hero-arrow-uturn-right" class="size-4" />
              </button>
            </div>
            <div :if={@can_edit} class="dropdown">
              <div tabindex="0" role="button" class="btn btn-sm btn-outline">
                <.icon name="hero-plus" class="size-4" /> Add node
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu bg-base-100 rounded-box z-20 w-44 p-2 shadow border border-base-200"
              >
                <li :for={type <- ~w(llm if_else template tool http_request code agent answer end)}>
                  <button phx-click="add_node" phx-value-type={type}>
                    <.icon name={meta(type).icon} class="size-4" /> {meta(type).label}
                  </button>
                </li>
              </ul>
            </div>
            <.link
              :if={@can_export}
              href={~p"/console/fluxes/#{@workflow.id}/export"}
              class="btn btn-sm btn-ghost"
              title="Download portable DSL"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Export
            </.link>
            <button class="btn btn-sm btn-ghost" phx-click="toggle_history">
              <.icon name="hero-clock" class="size-4" /> History
            </button>
            <button :if={@can_manage_tokens} class="btn btn-sm btn-ghost" phx-click="toggle_api">
              <.icon name="hero-key" class="size-4" /> API
            </button>
            <button :if={@can_edit} class="btn btn-sm btn-ghost" phx-click="toggle_triggers">
              <.icon name="hero-bolt" class="size-4" /> Triggers
            </button>
            <button
              :if={@can_manage_tokens}
              class="btn btn-sm btn-ghost"
              phx-click="toggle_site"
            >
              <.icon name="hero-globe-alt" class="size-4" /> Site
            </button>
            <button :if={@can_publish} class="btn btn-sm btn-outline" phx-click="publish">
              <.icon name="hero-rocket-launch" class="size-4" /> Publish
            </button>
            <button :if={@can_run} class="btn btn-sm btn-primary" phx-click="open_run">
              <.icon name="hero-play" class="size-4" /> Run
            </button>
          </div>
        </div>

        <div class="flex flex-1 min-h-0 gap-3">
          <div class="flex-1 min-w-0 relative rounded-box border border-base-300 bg-base-200/40">
            <div id="canvas-scroll" class="absolute inset-0 overflow-auto rounded-box">
              <div
                id="flux-canvas-surface"
                phx-hook=".FluxCanvas"
                data-scale={@zoom}
                class="relative cursor-grab"
                style={"width: 3000px; height: 1600px; transform: scale(#{@zoom / 100}); transform-origin: 0 0; background-image: radial-gradient(circle, oklch(70% 0 0 / 0.25) 1px, transparent 1px); background-size: 22px 22px;"}
              >
                <svg id="edge-layer" class="absolute inset-0 w-full h-full pointer-events-none">
                  <%= for edge <- @graph["edges"] || [], path = edge_path(@graph, edge), path != nil do %>
                    <g
                      class={[
                        "cursor-pointer",
                        (@selected_edge == edge["id"] && "text-primary") ||
                          "text-base-content/50 hover:text-primary"
                      ]}
                      style="pointer-events: auto;"
                    >
                      <path
                        d={path}
                        stroke="transparent"
                        stroke-width="12"
                        fill="none"
                        phx-click="select_edge"
                        phx-value-id={edge["id"]}
                      >
                        <title>Click to select; press Delete to remove</title>
                      </path>
                      <path
                        d={path}
                        stroke="currentColor"
                        stroke-width={(@selected_edge == edge["id"] && "3") || "2"}
                        fill="none"
                      />
                    </g>
                  <% end %>
                </svg>

                <div
                  :for={node <- @graph["nodes"] || []}
                  id={"node-#{node["id"]}"}
                  data-node={node["id"]}
                  data-selected={node["id"] in @selected_ids && "true"}
                  class={[
                    "absolute w-52 rounded-box border bg-base-100 shadow-sm select-none cursor-grab",
                    (node["id"] in @selected_ids && "border-primary shadow-md") ||
                      "border-base-300",
                    state_ring(@node_states[node["id"]])
                  ]}
                  style={"left: #{node_x(node)}px; top: #{node_y(node)}px;"}
                >
                  <div
                    data-drag-handle
                    class={[
                      "flex items-center gap-2 px-3 py-2 rounded-t-box",
                      meta(node["type"]).accent
                    ]}
                  >
                    <.icon name={meta(node["type"]).icon} class="size-4 shrink-0" />
                    <span class="text-sm font-semibold truncate">{node["title"]}</span>
                  </div>
                  <div class="px-3 py-2 text-xs opacity-70 truncate">{node_summary(node)}</div>

                  <span
                    :if={node["type"] != "start"}
                    data-in-port
                    data-node-id={node["id"]}
                    class="absolute -left-1.5 top-[22px] size-3 rounded-full bg-base-content/40 hover:bg-primary hover:scale-125 transition-transform"
                    title="Input"
                  >
                  </span>

                  <span
                    :if={node["type"] not in ["end", "if_else", "question_classifier"]}
                    data-out-port
                    data-node-id={node["id"]}
                    data-handle="default"
                    class="absolute -right-1.5 top-[22px] size-3 rounded-full bg-primary/70 hover:bg-primary hover:scale-125 transition-transform cursor-crosshair"
                    title="Drag to connect"
                  >
                  </span>

                  <%= if node["type"] == "question_classifier" do %>
                    <span
                      :for={
                        {class, index} <-
                          Enum.with_index(List.wrap(node["config"]["classes"]))
                      }
                      :if={class["id"] != ""}
                      data-out-port
                      data-node-id={node["id"]}
                      data-handle={class["id"]}
                      class="absolute -right-1.5 size-3 rounded-full bg-warning hover:scale-125 transition-transform cursor-crosshair"
                      style={"top: #{22 + index * 28}px"}
                      title={"Branch: #{class["id"]}"}
                    >
                    </span>
                  <% end %>

                  <span
                    :if={failable?(node["type"])}
                    data-out-port
                    data-node-id={node["id"]}
                    data-handle="error"
                    class="absolute -right-1.5 size-3 rounded-full bg-error/70 hover:bg-error hover:scale-125 transition-transform cursor-crosshair"
                    style={
                      (node["type"] == "question_classifier" &&
                         "top: #{22 + length(List.wrap(node["config"]["classes"])) * 28}px") ||
                        "top: 50px"
                    }
                    title="Error branch"
                  >
                  </span>

                  <%= if node["type"] == "if_else" do %>
                    <span
                      data-out-port
                      data-node-id={node["id"]}
                      data-handle="true"
                      class="absolute -right-1.5 top-[22px] size-3 rounded-full bg-success hover:scale-125 transition-transform cursor-crosshair"
                      title="True branch"
                    >
                    </span>
                    <span
                      data-out-port
                      data-node-id={node["id"]}
                      data-handle="false"
                      class="absolute -right-1.5 top-[50px] size-3 rounded-full bg-error hover:scale-125 transition-transform cursor-crosshair"
                      title="False branch"
                    >
                    </span>
                    <div class="absolute -right-8 top-[16px] text-[10px] text-success font-bold">
                      T
                    </div>
                    <div class="absolute -right-8 top-[44px] text-[10px] text-error font-bold">F</div>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="absolute bottom-3 left-3 z-10 join border border-base-300 bg-base-100 shadow-sm rounded-box">
              <button class="btn btn-xs btn-ghost join-item" phx-click="zoom" phx-value-dir="out">
                <.icon name="hero-minus" class="size-3" />
              </button>
              <button
                class="btn btn-xs btn-ghost join-item w-14 font-mono"
                phx-click="zoom"
                phx-value-dir="reset"
                title="Reset zoom"
              >
                {@zoom}%
              </button>
              <button class="btn btn-xs btn-ghost join-item" phx-click="zoom" phx-value-dir="in">
                <.icon name="hero-plus" class="size-3" />
              </button>
            </div>

            <div class="absolute bottom-3 right-3 z-10 rounded-box border border-base-300 bg-base-100/90 shadow-sm px-3 py-2 text-[11px] leading-5 hidden lg:block">
              <p>
                <kbd class="kbd kbd-xs">Shift</kbd>
                + click — select multiple · <kbd class="kbd kbd-xs">Shift</kbd>
                + drag — marquee select
              </p>
              <p>
                Drag canvas — pan · <kbd class="kbd kbd-xs">Ctrl</kbd>
                + scroll — zoom · drag a port — connect
              </p>
              <p>
                <kbd class="kbd kbd-xs">Del</kbd>
                — delete selection · <kbd class="kbd kbd-xs">Ctrl</kbd><kbd class="kbd kbd-xs">Z</kbd>
                undo ·
                <kbd class="kbd kbd-xs">Ctrl</kbd><kbd class="kbd kbd-xs">⇧</kbd><kbd class="kbd kbd-xs">Z</kbd>
                redo
              </p>
            </div>
          </div>

          <div
            :if={@selected_id != nil and selected_node_assign(@graph, @selected_id) != nil}
            class="w-80 shrink-0 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-4 space-y-4"
          >
            <% node = selected_node_assign(@graph, @selected_id) %>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <.icon name={meta(node["type"]).icon} class="size-4" />
                <h2 class="font-semibold">{meta(node["type"]).label}</h2>
              </div>
              <div class="flex items-center gap-1">
                <button
                  :if={@can_edit and node["type"] != "start"}
                  class="btn btn-ghost btn-xs"
                  phx-click="duplicate_node"
                  phx-value-id={node["id"]}
                  title="Duplicate this node"
                >
                  <.icon name="hero-document-duplicate" class="size-4" />
                </button>
                <button
                  :if={@can_edit and node["type"] != "start"}
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_node"
                  phx-value-id={node["id"]}
                  data-confirm="Delete this node?"
                >
                  Delete
                </button>
                <button class="btn btn-ghost btn-xs" phx-click="deselect">
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>

            <form phx-change="update_node" class="space-y-3">
              <label class="floating-label">
                <span>Title</span>
                <input
                  type="text"
                  name="title"
                  value={node["title"]}
                  class="input input-sm w-full"
                  disabled={not @can_edit}
                />
              </label>

              <%= case node["type"] do %>
                <% "start" -> %>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">Input variables</p>
                    <div
                      :for={
                        {variable, index} <- Enum.with_index(List.wrap(node["config"]["variables"]))
                      }
                      class="rounded-box border border-base-200 p-2 space-y-2"
                    >
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name={"vars[#{index}][name]"}
                          value={variable["name"]}
                          placeholder="name"
                          class="input input-xs flex-1"
                          disabled={not @can_edit}
                        />
                        <select
                          name={"vars[#{index}][type]"}
                          class="select select-xs w-24"
                          disabled={not @can_edit}
                        >
                          <option
                            :for={type <- ~w(text paragraph number)}
                            value={type}
                            selected={variable["type"] == type}
                          >
                            {type}
                          </option>
                        </select>
                      </div>
                      <div class="flex items-center justify-between">
                        <label class="flex items-center gap-1 text-xs">
                          <input
                            type="checkbox"
                            name={"vars[#{index}][required]"}
                            value="true"
                            checked={variable["required"] == true}
                            class="checkbox checkbox-xs"
                            disabled={not @can_edit}
                          /> required
                        </label>
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs text-error"
                          phx-click="remove_row"
                          phx-value-kind="variable"
                          phx-value-index={index}
                          disabled={not @can_edit}
                        >
                          Remove
                        </button>
                      </div>
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="variable"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add variable
                    </button>
                  </div>
                <% "llm" -> %>
                  <label class="floating-label">
                    <span>Model</span>
                    <select
                      name="model_choice"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["model"] in [nil, ""]}>
                        Choose a model…
                      </option>
                      <option
                        :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
                        value={"#{pid}|#{m.name}"}
                        selected={
                          node["config"]["provider_plugin_id"] == pid and
                            node["config"]["model"] == m.name
                        }
                      >
                        {pname} — {m.label}
                      </option>
                    </select>
                  </label>
                  <p :if={@models == []} class="text-xs text-warning">
                    No models available — configure a provider under Plugins first.
                  </p>
                  <label class="floating-label">
                    <span>System prompt</span>
                    <textarea
                      name="system_prompt"
                      rows="3"
                      class="textarea textarea-sm w-full"
                      disabled={not @can_edit}
                    >{node["config"]["system_prompt"]}</textarea>
                  </label>
                  <label class="floating-label">
                    <span>Prompt</span>
                    <textarea
                      name="prompt"
                      rows="4"
                      class="textarea textarea-sm w-full"
                      disabled={not @can_edit}
                    >{node["config"]["prompt"]}</textarea>
                  </label>
                <% "if_else" -> %>
                  <label class="floating-label">
                    <span>Combine with</span>
                    <select
                      name="logical_operator"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="and" selected={node["config"]["logical_operator"] != "or"}>
                        AND
                      </option>
                      <option value="or" selected={node["config"]["logical_operator"] == "or"}>
                        OR
                      </option>
                    </select>
                  </label>
                  <div class="space-y-2">
                    <div
                      :for={
                        {condition, index} <- Enum.with_index(List.wrap(node["config"]["conditions"]))
                      }
                      class="rounded-box border border-base-200 p-2 space-y-2"
                    >
                      <input
                        type="text"
                        name={"conds[#{index}][left]"}
                        value={condition["left"]}
                        placeholder="{{start.query}}"
                        class="input input-xs w-full"
                        disabled={not @can_edit}
                      />
                      <div class="flex gap-2">
                        <select
                          name={"conds[#{index}][operator]"}
                          class="select select-xs flex-1"
                          disabled={not @can_edit}
                        >
                          <option
                            :for={operator <- operators()}
                            value={operator}
                            selected={condition["operator"] == operator}
                          >
                            {String.replace(operator, "_", " ")}
                          </option>
                        </select>
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs text-error"
                          phx-click="remove_row"
                          phx-value-kind="condition"
                          phx-value-index={index}
                          disabled={not @can_edit}
                        >
                          ✕
                        </button>
                      </div>
                      <input
                        type="text"
                        name={"conds[#{index}][right]"}
                        value={condition["right"]}
                        placeholder="value"
                        class="input input-xs w-full"
                        disabled={not @can_edit}
                      />
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="condition"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add condition
                    </button>
                  </div>
                <% "template" -> %>
                  <label class="floating-label">
                    <span>Template</span>
                    <textarea
                      name="template"
                      rows="6"
                      class="textarea textarea-sm w-full font-mono"
                      disabled={not @can_edit}
                    >{node["config"]["template"]}</textarea>
                  </label>
                <% "http_request" -> %>
                  <div class="flex gap-2">
                    <select name="method" class="select select-sm w-28" disabled={not @can_edit}>
                      <option
                        :for={method <- ~w(get post put patch delete head)}
                        value={method}
                        selected={node["config"]["method"] == method}
                      >
                        {String.upcase(method)}
                      </option>
                    </select>
                    <input
                      type="text"
                      name="url"
                      value={node["config"]["url"]}
                      placeholder="https://api.example.com/{{start.id}}"
                      class="input input-sm flex-1 font-mono"
                      disabled={not @can_edit}
                    />
                  </div>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">Headers</p>
                    <div
                      :for={{header, index} <- Enum.with_index(List.wrap(node["config"]["headers"]))}
                      class="flex gap-2"
                    >
                      <input
                        type="text"
                        name={"hdrs[#{index}][key]"}
                        value={header["key"]}
                        placeholder="Authorization"
                        class="input input-xs w-28"
                        disabled={not @can_edit}
                      />
                      <input
                        type="text"
                        name={"hdrs[#{index}][value]"}
                        value={header["value"]}
                        placeholder="Bearer {{start.token}}"
                        class="input input-xs flex-1 font-mono"
                        disabled={not @can_edit}
                      />
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="remove_row"
                        phx-value-kind="header"
                        phx-value-index={index}
                        disabled={not @can_edit}
                      >
                        ✕
                      </button>
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="header"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add header
                    </button>
                  </div>
                  <label class="floating-label">
                    <span>Body (optional)</span>
                    <textarea
                      name="body"
                      rows="4"
                      class="textarea textarea-sm w-full font-mono"
                      disabled={not @can_edit}
                    >{node["config"]["body"]}</textarea>
                  </label>
                <% "code" -> %>
                  <label class="floating-label">
                    <span>Language</span>
                    <select name="language" class="select select-sm w-full" disabled={not @can_edit}>
                      <option
                        :for={lang <- ~w(python3 javascript typescript bash)}
                        value={lang}
                        selected={node["config"]["language"] == lang}
                      >
                        {lang}
                      </option>
                    </select>
                  </label>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">Inputs → main() arguments</p>
                    <div
                      :for={{input, index} <- Enum.with_index(List.wrap(node["config"]["inputs"]))}
                      class="flex gap-2"
                    >
                      <input
                        type="text"
                        name={"cins[#{index}][name]"}
                        value={input["name"]}
                        placeholder="arg name"
                        class="input input-xs w-28 font-mono"
                        disabled={not @can_edit}
                      />
                      <input
                        type="text"
                        name={"cins[#{index}][value]"}
                        value={input["value"]}
                        placeholder="{{start.query}}"
                        class="input input-xs flex-1 font-mono"
                        disabled={not @can_edit}
                      />
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="remove_row"
                        phx-value-kind="code_input"
                        phx-value-index={index}
                        disabled={not @can_edit}
                      >
                        x
                      </button>
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="code_input"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add input
                    </button>
                  </div>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">
                      Dependencies (installed per block, cached)
                    </p>
                    <div
                      :for={
                        {dep, index} <- Enum.with_index(List.wrap(node["config"]["dependencies"]))
                      }
                      class="flex gap-2"
                    >
                      <input
                        type="text"
                        name={"deps[#{index}][name]"}
                        value={dep["name"]}
                        placeholder="pandas"
                        class="input input-xs flex-1 font-mono"
                        disabled={not @can_edit}
                      />
                      <input
                        type="text"
                        name={"deps[#{index}][version]"}
                        value={dep["version"]}
                        placeholder="2.2.*"
                        class="input input-xs w-24 font-mono"
                        disabled={not @can_edit}
                      />
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="remove_row"
                        phx-value-kind="dependency"
                        phx-value-index={index}
                        disabled={not @can_edit}
                      >
                        x
                      </button>
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="dependency"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add dependency
                    </button>
                  </div>
                  <label class="floating-label">
                    <span>Code — define main(...) returning a dict</span>
                    <textarea
                      name="code"
                      rows="10"
                      class="textarea textarea-sm w-full font-mono text-xs"
                      spellcheck="false"
                      disabled={not @can_edit}
                    >{node["config"]["code"]}</textarea>
                  </label>
                <% "agent" -> %>
                  <label class="floating-label">
                    <span>Model</span>
                    <select
                      name="model_choice"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["model"] in [nil, ""]}>
                        Choose a model…
                      </option>
                      <option
                        :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
                        value={"#{pid}|#{m.name}"}
                        selected={
                          node["config"]["provider_plugin_id"] == pid and
                            node["config"]["model"] == m.name
                        }
                      >
                        {pname} — {m.label}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Toolset (every operation becomes a callable tool)</span>
                    <select
                      name="agent_toolset_id"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["agent_toolset_id"] in [nil, ""]}>
                        No tools
                      </option>
                      <option
                        :for={toolset <- @toolsets}
                        value={toolset.id}
                        selected={node["config"]["agent_toolset_id"] == toolset.id}
                      >
                        {toolset.name} ({length(toolset.operations)} ops)
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Instructions</span>
                    <textarea
                      name="instructions"
                      rows="3"
                      class="textarea textarea-sm w-full"
                      disabled={not @can_edit}
                    >{node["config"]["instructions"]}</textarea>
                  </label>
                  <label class="floating-label">
                    <span>Task / query</span>
                    <textarea
                      name="query"
                      rows="3"
                      class="textarea textarea-sm w-full font-mono"
                      disabled={not @can_edit}
                    >{node["config"]["query"]}</textarea>
                  </label>
                  <label class="floating-label">
                    <span>Max iterations (1–25)</span>
                    <input
                      type="number"
                      name="max_iterations"
                      value={node["config"]["max_iterations"] || 5}
                      min="1"
                      max="25"
                      class="input input-sm w-24"
                      disabled={not @can_edit}
                    />
                  </label>
                  <label class="floating-label">
                    <span>Output schema (JSON, optional — forces a structured final_output)</span>
                    <textarea
                      name="output_schema"
                      rows="3"
                      class="textarea textarea-sm w-full font-mono"
                      placeholder={~s({"type": "object", "properties": {...}})}
                      disabled={not @can_edit}
                    >{node["config"]["output_schema"] && Jason.encode!(node["config"]["output_schema"])}</textarea>
                  </label>
                <% "tool" -> %>
                  <label class="floating-label">
                    <span>API toolset</span>
                    <select name="toolset_id" class="select select-sm w-full" disabled={not @can_edit}>
                      <option value="" selected={node["config"]["toolset_id"] in [nil, ""]}>
                        Choose a toolset…
                      </option>
                      <option
                        :for={toolset <- @toolsets}
                        value={toolset.id}
                        selected={node["config"]["toolset_id"] == toolset.id}
                      >
                        {toolset.name}
                      </option>
                    </select>
                  </label>
                  <p :if={@toolsets == []} class="text-xs text-warning">
                    No toolsets yet — import an OpenAPI spec under Tools first.
                  </p>
                  <label :if={node["config"]["toolset_id"] not in [nil, ""]} class="floating-label">
                    <span>Operation</span>
                    <select
                      name="operation_id"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["operation_id"] in [nil, ""]}>
                        Choose an operation…
                      </option>
                      <option
                        :for={operation <- operations_for(@toolsets, node["config"]["toolset_id"])}
                        value={operation["operation_id"]}
                        selected={node["config"]["operation_id"] == operation["operation_id"]}
                      >
                        {String.upcase(operation["method"])} {operation["path"]}
                      </option>
                    </select>
                  </label>
                  <div
                    :if={selected_operation(@toolsets, node["config"]) != nil}
                    class="space-y-2"
                  >
                    <p class="text-xs font-semibold opacity-70">Arguments</p>
                    <div
                      :for={param <- selected_operation(@toolsets, node["config"])["params"]}
                      class="space-y-1"
                    >
                      <label class="text-xs opacity-70">
                        {param["name"]}
                        <span class="opacity-50">({param["in"]})</span>
                        <span :if={param["required"]} class="text-error">*</span>
                      </label>
                      <input
                        type="text"
                        name={"args[#{param["name"]}]"}
                        value={node["config"]["args"][param["name"]]}
                        placeholder="{{start.query}} or {{vars.secret}}"
                        class="input input-xs w-full font-mono"
                        disabled={not @can_edit}
                      />
                    </div>
                  </div>
                <% "answer" -> %>
                  <label class="floating-label">
                    <span>Answer</span>
                    <textarea
                      name="answer"
                      rows="5"
                      class="textarea textarea-sm w-full"
                      disabled={not @can_edit}
                    >{node["config"]["answer"]}</textarea>
                  </label>
                <% "end" -> %>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">Outputs</p>
                    <div
                      :for={{output, index} <- Enum.with_index(List.wrap(node["config"]["outputs"]))}
                      class="rounded-box border border-base-200 p-2 space-y-2"
                    >
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name={"outs[#{index}][key]"}
                          value={output["key"]}
                          placeholder="key"
                          class="input input-xs w-24"
                          disabled={not @can_edit}
                        />
                        <input
                          type="text"
                          name={"outs[#{index}][value]"}
                          value={output["value"]}
                          placeholder="{{llm_1.text}}"
                          class="input input-xs flex-1"
                          disabled={not @can_edit}
                        />
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs text-error"
                          phx-click="remove_row"
                          phx-value-kind="output"
                          phx-value-index={index}
                          disabled={not @can_edit}
                        >
                          ✕
                        </button>
                      </div>
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="output"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add output
                    </button>
                  </div>
                <% "question_classifier" -> %>
                  <label class="floating-label">
                    <span>Model</span>
                    <select
                      name="model_choice"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["model"] in [nil, ""]}>
                        Workspace default
                      </option>
                      <option
                        :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
                        value={"#{pid}|#{m.name}"}
                        selected={
                          node["config"]["provider_plugin_id"] == pid and
                            node["config"]["model"] == m.name
                        }
                      >
                        {pname} — {m.label}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Input to classify</span>
                    <input
                      type="text"
                      name="query"
                      value={node["config"]["query"]}
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <label class="floating-label">
                    <span>Extra instructions (optional)</span>
                    <textarea
                      name="instruction"
                      rows="2"
                      class="textarea textarea-sm w-full"
                      disabled={not @can_edit}
                    >{node["config"]["instruction"]}</textarea>
                  </label>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">
                      Classes (each becomes an output branch)
                    </p>
                    <div
                      :for={{class, index} <- Enum.with_index(List.wrap(node["config"]["classes"]))}
                      class="flex gap-2"
                    >
                      <input
                        type="text"
                        name={"cls[#{index}][id]"}
                        value={class["id"]}
                        placeholder="id"
                        class="input input-xs w-24 font-mono"
                        disabled={not @can_edit}
                      />
                      <input
                        type="text"
                        name={"cls[#{index}][name]"}
                        value={class["name"]}
                        placeholder="What this class means"
                        class="input input-xs flex-1"
                        disabled={not @can_edit}
                      />
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="remove_row"
                        phx-value-kind="class"
                        phx-value-index={index}
                        disabled={not @can_edit}
                      >
                        ✕
                      </button>
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="class"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add class
                    </button>
                  </div>
                <% "parameter_extractor" -> %>
                  <label class="floating-label">
                    <span>Model</span>
                    <select
                      name="model_choice"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["model"] in [nil, ""]}>
                        Workspace default
                      </option>
                      <option
                        :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
                        value={"#{pid}|#{m.name}"}
                        selected={
                          node["config"]["provider_plugin_id"] == pid and
                            node["config"]["model"] == m.name
                        }
                      >
                        {pname} — {m.label}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Input to extract from</span>
                    <input
                      type="text"
                      name="query"
                      value={node["config"]["query"]}
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <label class="floating-label">
                    <span>Extra instructions (optional)</span>
                    <textarea
                      name="instruction"
                      rows="2"
                      class="textarea textarea-sm w-full"
                      disabled={not @can_edit}
                    >{node["config"]["instruction"]}</textarea>
                  </label>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">Parameters</p>
                    <div
                      :for={
                        {parameter, index} <-
                          Enum.with_index(List.wrap(node["config"]["parameters"]))
                      }
                      class="rounded-box border border-base-200 p-2 space-y-1"
                    >
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name={"prms[#{index}][name]"}
                          value={parameter["name"]}
                          placeholder="name"
                          class="input input-xs w-28 font-mono"
                          disabled={not @can_edit}
                        />
                        <select
                          name={"prms[#{index}][type]"}
                          class="select select-xs w-24"
                          disabled={not @can_edit}
                        >
                          <option
                            :for={type <- ~w(string number bool)}
                            value={type}
                            selected={(parameter["type"] || "string") == type}
                          >
                            {type}
                          </option>
                        </select>
                        <label class="flex items-center gap-1 text-xs">
                          <input
                            type="hidden"
                            name={"prms[#{index}][required]"}
                            value="false"
                          />
                          <input
                            type="checkbox"
                            name={"prms[#{index}][required]"}
                            value="true"
                            checked={parameter["required"] == true}
                            class="checkbox checkbox-xs"
                            disabled={not @can_edit}
                          /> required
                        </label>
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs text-error ml-auto"
                          phx-click="remove_row"
                          phx-value-kind="parameter"
                          phx-value-index={index}
                          disabled={not @can_edit}
                        >
                          ✕
                        </button>
                      </div>
                      <input
                        type="text"
                        name={"prms[#{index}][description]"}
                        value={parameter["description"]}
                        placeholder="What to extract"
                        class="input input-xs w-full"
                        disabled={not @can_edit}
                      />
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="parameter"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add parameter
                    </button>
                  </div>
                <% "variable_aggregator" -> %>
                  <label class="floating-label">
                    <span>Selectors (one per line, first non-empty wins)</span>
                    <textarea
                      name="variables_text"
                      rows="4"
                      placeholder="llm_1.text\nllm_2.text"
                      class="textarea textarea-sm w-full font-mono"
                      disabled={not @can_edit}
                    >{Enum.join(List.wrap(node["config"]["variables"]), "\n")}</textarea>
                  </label>
                <% "variable_assigner" -> %>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold opacity-70">Assignments</p>
                    <div
                      :for={
                        {assignment, index} <-
                          Enum.with_index(List.wrap(node["config"]["assignments"]))
                      }
                      class="flex gap-2"
                    >
                      <input
                        type="text"
                        name={"asgn[#{index}][name]"}
                        value={assignment["name"]}
                        placeholder="variable"
                        class="input input-xs w-28 font-mono"
                        disabled={not @can_edit}
                      />
                      <input
                        type="text"
                        name={"asgn[#{index}][value]"}
                        value={assignment["value"]}
                        placeholder="{{llm_1.text}}"
                        class="input input-xs flex-1 font-mono"
                        disabled={not @can_edit}
                      />
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="remove_row"
                        phx-value-kind="assignment"
                        phx-value-index={index}
                        disabled={not @can_edit}
                      >
                        ✕
                      </button>
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_row"
                      phx-value-kind="assignment"
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add assignment
                    </button>
                  </div>
                <% "list_operator" -> %>
                  <label class="floating-label">
                    <span>List variable</span>
                    <input
                      type="text"
                      name="variable"
                      value={node["config"]["variable"]}
                      placeholder="code_1.items"
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <div class="flex gap-2">
                    <label class="floating-label flex-1">
                      <span>Filter</span>
                      <select
                        name="filter_operator"
                        class="select select-sm w-full"
                        disabled={not @can_edit}
                      >
                        <option value="" selected={node["config"]["filter"]["operator"] in [nil, ""]}>
                          No filter
                        </option>
                        <option
                          :for={operator <- ~w(contains not_contains eq neq gt lt not_empty)}
                          value={operator}
                          selected={node["config"]["filter"]["operator"] == operator}
                        >
                          {operator}
                        </option>
                      </select>
                    </label>
                    <label class="floating-label flex-1">
                      <span>Filter value</span>
                      <input
                        type="text"
                        name="filter_value"
                        value={node["config"]["filter"]["value"]}
                        class="input input-sm w-full font-mono"
                        disabled={not @can_edit}
                      />
                    </label>
                  </div>
                  <div class="flex gap-2">
                    <label class="floating-label">
                      <span>Sort</span>
                      <select name="sort" class="select select-sm w-28" disabled={not @can_edit}>
                        <option
                          :for={sort <- ~w(none asc desc)}
                          value={sort}
                          selected={(node["config"]["sort"] || "none") == sort}
                        >
                          {sort}
                        </option>
                      </select>
                    </label>
                    <label class="floating-label">
                      <span>Limit</span>
                      <input
                        type="number"
                        name="limit"
                        value={node["config"]["limit"]}
                        min="1"
                        class="input input-sm w-24"
                        disabled={not @can_edit}
                      />
                    </label>
                  </div>
                <% _other -> %>
              <% end %>

              <label
                :if={failable?(node["type"])}
                class="floating-label border-t border-base-200 pt-3 mt-1 block"
              >
                <span>Retries on failure (0–5; wire the red port for an error branch)</span>
                <input
                  type="number"
                  name="max_retries"
                  value={node["config"]["retry"]["max_retries"] || 0}
                  min="0"
                  max="5"
                  class="input input-sm w-24"
                  disabled={not @can_edit}
                />
              </label>
            </form>

            <div :if={variable_hints(@graph, @selected_id) != []} class="space-y-1">
              <p class="text-xs font-semibold opacity-70">Available variables</p>
              <div class="flex flex-wrap gap-1">
                <code
                  :for={hint <- variable_hints(@graph, @selected_id)}
                  class="badge badge-ghost badge-sm font-mono"
                >
                  {hint}
                </code>
              </div>
            </div>
          </div>

          <div
            :if={@show_run}
            class="w-96 shrink-0 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-4 space-y-4"
          >
            <div class="flex items-center justify-between">
              <h2 class="font-semibold">Run</h2>
              <button class="btn btn-ghost btn-xs" phx-click="close_run">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <form phx-submit="start_run" class="space-y-3">
              <div :for={variable <- start_variables(@graph)} class="space-y-1">
                <label class="text-xs font-semibold opacity-70">
                  {variable["name"]}
                  <span :if={variable["required"]} class="text-error">*</span>
                </label>
                <%= if variable["type"] == "paragraph" do %>
                  <textarea
                    name={"inputs[#{variable["name"]}]"}
                    rows="3"
                    class="textarea textarea-sm w-full"
                  ></textarea>
                <% else %>
                  <input
                    type={(variable["type"] == "number" && "number") || "text"}
                    name={"inputs[#{variable["name"]}]"}
                    class="input input-sm w-full"
                  />
                <% end %>
              </div>
              <div class="flex gap-2">
                <button
                  class="btn btn-primary btn-sm"
                  disabled={@run != nil and @run.status == :running}
                >
                  <.icon name="hero-play" class="size-4" /> Run flux
                </button>
                <button
                  :if={@run != nil and @run.status == :running}
                  type="button"
                  class="btn btn-warning btn-sm"
                  phx-click="stop_run"
                >
                  Stop
                </button>
              </div>
            </form>

            <div :if={@node_states != %{}} class="space-y-1">
              <p class="text-xs font-semibold opacity-70">Nodes</p>
              <div class="flex flex-wrap gap-1">
                <span
                  :for={{node_id, state} <- @node_states}
                  class={[
                    "badge badge-sm",
                    state == :running && "badge-info",
                    state == :done && "badge-success",
                    state == :error && "badge-error"
                  ]}
                >
                  {node_id}
                </span>
              </div>
            </div>

            <div :if={@run_text != ""} class="space-y-1">
              <p class="text-xs font-semibold opacity-70">Output</p>
              <div class="rounded-box bg-base-200 p-3 text-sm whitespace-pre-wrap">{@run_text}</div>
            </div>

            <div :if={@run != nil and @run.status != :running} class="space-y-2">
              <div class="flex items-center gap-2">
                <span class={[
                  "badge badge-sm",
                  @run.status == :succeeded && "badge-success",
                  @run.status == :failed && "badge-error",
                  @run.status == :stopped && "badge-warning"
                ]}>
                  {@run.status}
                </span>
                <span :if={@run.elapsed_ms} class="text-xs opacity-60">{@run.elapsed_ms} ms</span>
              </div>
              <p :if={@run.error} class="text-sm text-error">{@run.error}</p>
              <div :if={@run.outputs != %{}} class="space-y-1">
                <p class="text-xs font-semibold opacity-70">Final outputs</p>
                <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{Jason.encode!(@run.outputs, pretty: true)}</pre>
              </div>
            </div>
          </div>

          <div
            :if={@show_history}
            class="w-96 shrink-0 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-4 space-y-3"
          >
            <div class="flex items-center justify-between">
              <h2 class="font-semibold">Run history</h2>
              <button class="btn btn-ghost btn-xs" phx-click="toggle_history">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p :if={@runs == []} class="text-sm opacity-60">
              No runs yet — run the draft or call the API.
            </p>

            <div
              :for={run <- @runs}
              class="rounded-box border border-base-200 overflow-hidden"
              id={"run-#{run.id}"}
            >
              <button
                type="button"
                class="w-full flex items-center gap-2 px-3 py-2 text-left hover:bg-base-200/60"
                phx-click="select_run"
                phx-value-id={run.id}
              >
                <span class={[
                  "badge badge-sm",
                  run.status == :succeeded && "badge-success",
                  run.status == :failed && "badge-error",
                  run.status == :stopped && "badge-warning",
                  run.status == :running && "badge-info"
                ]}>
                  {run.status}
                </span>
                <span class="badge badge-ghost badge-sm">
                  {(run.version && "v#{run.version}") || "draft"}
                </span>
                <span class="text-xs opacity-60">{run.source}</span>
                <span class="ml-auto text-xs opacity-60">
                  {Calendar.strftime(run.inserted_at, "%m-%d %H:%M:%S")}
                </span>
              </button>

              <div :if={@selected_run_id == run.id} class="border-t border-base-200 p-3 space-y-2">
                <p :if={run.error} class="text-sm text-error">{run.error}</p>
                <div
                  :for={execution <- run.node_executions}
                  class="flex items-start gap-2 text-xs"
                >
                  <.icon
                    name={
                      (execution["status"] == "succeeded" && "hero-check-circle") ||
                        "hero-x-circle"
                    }
                    class={[
                      "size-4 shrink-0 mt-0.5",
                      (execution["status"] == "succeeded" && "text-success") || "text-error"
                    ]}
                  />
                  <div class="min-w-0 flex-1">
                    <p class="font-semibold">
                      {execution["title"]}
                      <span class="opacity-50 font-normal">
                        · {execution["node_type"]} · {execution["elapsed_ms"]} ms
                      </span>
                    </p>
                    <p :if={execution["error"]} class="text-error">{execution["error"]}</p>
                    <pre
                      :if={execution["outputs"] not in [nil, %{}]}
                      class="mt-1 rounded bg-base-200 p-2 overflow-x-auto max-h-32"
                    >{Jason.encode!(execution["outputs"], pretty: true)}</pre>
                  </div>
                </div>
                <div :if={run.outputs != %{}} class="space-y-1">
                  <p class="font-semibold text-xs opacity-70">Final outputs</p>
                  <pre class="rounded bg-base-200 p-2 text-xs overflow-x-auto">{Jason.encode!(run.outputs, pretty: true)}</pre>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <dialog :if={@show_api} class="modal modal-open">
        <div class="modal-box space-y-4">
          <div class="flex items-center justify-between">
            <h3 class="font-bold">API access</h3>
            <button class="btn btn-ghost btn-xs" phx-click="toggle_api">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <p class="text-sm opacity-70">
            Publish this flux, then call it with a workflow API key:
          </p>
          <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{api_snippet()}</pre>
          <div :if={@new_token_raw} class="alert alert-success text-sm">
            <div>
              <p class="font-semibold">Copy this key now — it won't be shown again:</p>
              <code class="font-mono break-all">{@new_token_raw}</code>
            </div>
          </div>
          <table :if={@tokens != []} class="table table-sm">
            <thead>
              <tr>
                <th>Key</th>
                <th>Last used</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={token <- @tokens}>
                <td class="font-mono text-xs">{token.prefix}</td>
                <td class="text-xs opacity-60">
                  {(token.last_used_at && Calendar.strftime(token.last_used_at, "%Y-%m-%d %H:%M")) ||
                    "never"}
                </td>
                <td>
                  <button
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="revoke_token"
                    phx-value-token-id={token.id}
                    data-confirm="Revoke this key?"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
          <button class="btn btn-primary btn-sm" phx-click="create_token">
            <.icon name="hero-plus" class="size-4" /> Create API key
          </button>
        </div>
        <div class="modal-backdrop" phx-click="toggle_api"></div>
      </dialog>

      <dialog :if={@show_site} class="modal modal-open">
        <div class="modal-box space-y-4">
          <div class="flex items-center justify-between">
            <h3 class="font-bold">Site publishing</h3>
            <button class="btn btn-ghost btn-xs" phx-click="toggle_site">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <p class="text-sm opacity-70">
            Publish this flux at a public form URL anyone can use — no login required.
            The public page always runs the latest <span class="font-semibold">published</span>
            version, so publish a version first.
          </p>
          <button
            :if={not @workflow.site_enabled}
            class="btn btn-primary btn-sm"
            phx-click="enable_site"
          >
            <.icon name="hero-globe-alt" class="size-4" /> Publish site
          </button>
          <div :if={@workflow.site_enabled} class="space-y-2">
            <p class="text-sm">
              Live at
              <a
                href={url(~p"/site/flux/#{@workflow.site_token}")}
                target="_blank"
                class="link link-primary font-mono text-xs"
              >
                {url(~p"/site/flux/#{@workflow.site_token}")}
              </a>
            </p>
            <p class="text-xs opacity-60">Embed it on any page:</p>
            <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{flux_embed_snippet(@workflow)}</pre>
            <p class="text-xs opacity-60">Or as a floating bubble:</p>
            <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{flux_bubble_snippet(@workflow)}</pre>
            <button
              class="btn btn-ghost btn-sm text-error"
              phx-click="disable_site"
              data-confirm="Unpublish the public site?"
            >
              Unpublish
            </button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="toggle_site"></div>
      </dialog>

      <dialog :if={@show_triggers} class="modal modal-open">
        <div class="modal-box max-w-2xl space-y-4">
          <div class="flex items-center justify-between">
            <h3 class="font-bold">Triggers</h3>
            <button class="btn btn-ghost btn-xs" phx-click="toggle_triggers">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <p class="text-sm opacity-70">
            Triggers start the latest <span class="font-semibold">published</span>
            version of this flux from the outside — publish first, then wire up a
            webhook or a schedule.
          </p>

          <p :if={@triggers == []} class="text-sm opacity-60">No triggers yet.</p>

          <div
            :for={trigger <- @triggers}
            class="rounded-box border border-base-200 p-3 space-y-2"
            id={"trigger-#{trigger.id}"}
          >
            <div class="flex items-center gap-2">
              <span class={[
                "badge badge-sm",
                (trigger.type == :webhook && "badge-info") || "badge-accent"
              ]}>
                {trigger.type}
              </span>
              <span :if={trigger.type == :schedule} class="text-xs opacity-70">
                every {trigger.interval_minutes} min
              </span>
              <span :if={not trigger.enabled} class="badge badge-ghost badge-sm">disabled</span>
              <span class="ml-auto text-xs opacity-60">
                last run: {(trigger.last_run_at &&
                              Calendar.strftime(trigger.last_run_at, "%Y-%m-%d %H:%M")) || "never"}
              </span>
            </div>
            <pre
              :if={trigger.type == :webhook}
              class="rounded bg-base-200 p-2 text-xs overflow-x-auto"
            >POST {url(~p"/triggers/webhook/#{trigger.token}")}</pre>
            <pre
              :if={trigger.inputs != %{}}
              class="rounded bg-base-200 p-2 text-xs overflow-x-auto"
            >{Jason.encode!(trigger.inputs)}</pre>
            <div class="flex items-center gap-2">
              <button
                class="btn btn-ghost btn-xs"
                phx-click="toggle_trigger"
                phx-value-trigger-id={trigger.id}
                phx-value-enabled={to_string(not trigger.enabled)}
              >
                {(trigger.enabled && "Disable") || "Enable"}
              </button>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="delete_trigger"
                phx-value-trigger-id={trigger.id}
                data-confirm="Delete this trigger?"
              >
                Delete
              </button>
            </div>
          </div>

          <form
            phx-submit="create_trigger"
            phx-change="trigger_form_change"
            class="rounded-box border border-base-300 p-3 space-y-3"
          >
            <div class="flex items-end gap-3 flex-wrap">
              <label class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Type</span>
                <select name="type" class="select select-bordered select-sm">
                  <option value="webhook" selected={@trigger_type == "webhook"}>Webhook</option>
                  <option value="schedule" selected={@trigger_type == "schedule"}>Schedule</option>
                </select>
              </label>
              <label :if={@trigger_type == "schedule"} class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Interval (minutes)</span>
                <input
                  type="number"
                  name="interval_minutes"
                  min="1"
                  value="60"
                  class="input input-bordered input-sm w-32"
                />
              </label>
            </div>
            <label class="form-control block">
              <span class="label-text text-xs opacity-70 mb-1">
                Static inputs (JSON object, optional — webhook payloads override these)
              </span>
              <textarea
                name="inputs"
                rows="2"
                placeholder={~s({"query": "…"})}
                class="textarea textarea-bordered textarea-sm w-full font-mono"
              ></textarea>
            </label>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="size-4" /> Create trigger
            </button>
          </form>
        </div>
        <div class="modal-backdrop" phx-click="toggle_triggers"></div>
      </dialog>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".FluxCanvas">
        export default {
          mounted() {
            const surface = this.el
            const svgId = "edge-layer"
            const scroller = document.getElementById("canvas-scroll")

            const scale = () => (parseFloat(surface.dataset.scale) || 100) / 100

            const surfacePoint = (e) => {
              const rect = surface.getBoundingClientRect()
              const s = scale()
              return {x: (e.clientX - rect.left) / s, y: (e.clientY - rect.top) / s}
            }

            let drag = null

            surface.addEventListener("pointerdown", (e) => {
              const out = e.target.closest("[data-out-port]")
              if (out) {
                e.preventDefault()
                e.stopPropagation()
                const rect = out.getBoundingClientRect()
                const srect = surface.getBoundingClientRect()
                const s = scale()
                const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
                path.setAttribute("stroke", "currentColor")
                path.setAttribute("stroke-width", "2")
                path.setAttribute("stroke-dasharray", "5 4")
                path.setAttribute("fill", "none")
                path.setAttribute("opacity", "0.6")
                surface.querySelector("#" + svgId).appendChild(path)
                drag = {
                  kind: "connect",
                  source: out.dataset.nodeId,
                  handle: out.dataset.handle,
                  x0: (rect.left + rect.width / 2 - srect.left) / s,
                  y0: (rect.top + rect.height / 2 - srect.top) / s,
                  path: path
                }
                return
              }

              // The whole node card selects and drags; ports were handled above.
              const nodeEl = e.target.closest("[data-node]")
              if (nodeEl) {
                e.preventDefault()
                const wasSelected = nodeEl.hasAttribute("data-selected")
                if (!wasSelected) {
                  this.pushEvent("select_node", {id: nodeEl.dataset.node, shift: e.shiftKey})
                }

                // Group move: dragging a selected node carries the whole
                // selection with it.
                let group
                if (wasSelected || e.shiftKey) {
                  group = Array.from(surface.querySelectorAll("[data-node][data-selected]"))
                  if (!group.includes(nodeEl)) group.push(nodeEl)
                } else {
                  group = [nodeEl]
                }

                drag = {
                  kind: "node",
                  id: nodeEl.dataset.node,
                  wasSelected: wasSelected,
                  shift: e.shiftKey,
                  start: surfacePoint(e),
                  members: group.map((el) => ({el: el, x: el.offsetLeft, y: el.offsetTop})),
                  moved: false
                }
                return
              }

              // Empty canvas: drag pans, a plain click deselects.
              if (e.target === surface) {
                if (e.shiftKey) {
                  // Shift-drag on empty canvas: marquee selection.
                  const p = surfacePoint(e)
                  const box = document.createElement("div")
                  box.className =
                    "absolute border-2 border-primary/60 bg-primary/10 pointer-events-none z-20"
                  surface.appendChild(box)
                  drag = {kind: "marquee", x0: p.x, y0: p.y, x1: p.x, y1: p.y, box: box}
                  return
                }

                drag = {
                  kind: "pan",
                  sx: e.clientX,
                  sy: e.clientY,
                  sl: scroller.scrollLeft,
                  st: scroller.scrollTop,
                  moved: false
                }
                surface.style.cursor = "grabbing"
              }
            })

            this.onMove = (e) => {
              if (!drag) return
              if (drag.kind === "pan") {
                scroller.scrollLeft = drag.sl - (e.clientX - drag.sx)
                scroller.scrollTop = drag.st - (e.clientY - drag.sy)
                if (Math.abs(e.clientX - drag.sx) + Math.abs(e.clientY - drag.sy) > 3) {
                  drag.moved = true
                }
                return
              }
              const p = surfacePoint(e)
              if (drag.kind === "node") {
                const dx = p.x - drag.start.x
                const dy = p.y - drag.start.y
                if (Math.abs(dx) + Math.abs(dy) > 2) drag.moved = true
                for (const m of drag.members) {
                  m.cx = Math.max(0, m.x + dx)
                  m.cy = Math.max(0, m.y + dy)
                  m.el.style.left = m.cx + "px"
                  m.el.style.top = m.cy + "px"
                }
              } else if (drag.kind === "marquee") {
                drag.x1 = p.x
                drag.y1 = p.y
                const left = Math.min(drag.x0, drag.x1)
                const top = Math.min(drag.y0, drag.y1)
                drag.box.style.left = left + "px"
                drag.box.style.top = top + "px"
                drag.box.style.width = Math.abs(drag.x1 - drag.x0) + "px"
                drag.box.style.height = Math.abs(drag.y1 - drag.y0) + "px"
              } else {
                const d =
                  "M " + drag.x0 + " " + drag.y0 +
                  " C " + (drag.x0 + 60) + " " + drag.y0 +
                  ", " + (p.x - 60) + " " + p.y +
                  ", " + p.x + " " + p.y
                drag.path.setAttribute("d", d)
              }
            }

            this.onUp = (e) => {
              if (!drag) return
              if (drag.kind === "pan") {
                surface.style.cursor = ""
                if (!drag.moved) this.pushEvent("deselect", {})
              } else if (drag.kind === "node") {
                if (drag.moved) {
                  const moves = drag.members
                    .filter((m) => m.cx !== undefined)
                    .map((m) => ({
                      id: m.el.dataset.node,
                      x: Math.round(m.cx),
                      y: Math.round(m.cy)
                    }))
                  if (moves.length > 0) this.pushEvent("nodes_moved", {moves: moves})
                } else if (drag.wasSelected) {
                  // Click (no movement) on an already-selected node: plain
                  // click collapses to just it, shift-click toggles it off.
                  this.pushEvent("select_node", {id: drag.id, shift: drag.shift})
                }
              } else if (drag.kind === "marquee") {
                drag.box.remove()
                const left = Math.min(drag.x0, drag.x1)
                const right = Math.max(drag.x0, drag.x1)
                const top = Math.min(drag.y0, drag.y1)
                const bottom = Math.max(drag.y0, drag.y1)
                const ids = Array.from(surface.querySelectorAll("[data-node]"))
                  .filter((el) => {
                    return el.offsetLeft < right &&
                      el.offsetLeft + el.offsetWidth > left &&
                      el.offsetTop < bottom &&
                      el.offsetTop + el.offsetHeight > top
                  })
                  .map((el) => el.dataset.node)
                this.pushEvent("marquee_select", {ids: ids})
              } else {
                drag.path.remove()
                const target = e.target.closest ? e.target.closest("[data-in-port]") : null
                if (target && target.dataset.nodeId !== drag.source) {
                  this.pushEvent("connect", {
                    source: drag.source,
                    source_handle: drag.handle,
                    target: target.dataset.nodeId
                  })
                }
              }
              drag = null
            }

            this.onKey = (e) => {
              const t = e.target
              if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" ||
                        t.tagName === "SELECT" || t.isContentEditable)) return
              const mod = e.ctrlKey || e.metaKey
              const key = e.key.toLowerCase()
              if (mod && key === "z" && !e.shiftKey) {
                e.preventDefault()
                this.pushEvent("undo", {})
              } else if ((mod && key === "z" && e.shiftKey) || (mod && key === "y")) {
                e.preventDefault()
                this.pushEvent("redo", {})
              } else if (e.key === "Delete" || e.key === "Backspace") {
                this.pushEvent("delete_selection", {})
              }
            }

            this.onWheel = (e) => {
              if (!e.ctrlKey) return
              e.preventDefault()
              const now = Date.now()
              if (this.lastZoom && now - this.lastZoom < 120) return
              this.lastZoom = now
              this.pushEvent("zoom", {dir: e.deltaY < 0 ? "in" : "out"})
            }

            window.addEventListener("pointermove", this.onMove)
            window.addEventListener("pointerup", this.onUp)
            window.addEventListener("keydown", this.onKey)
            scroller.addEventListener("wheel", this.onWheel, {passive: false})
          },
          destroyed() {
            window.removeEventListener("pointermove", this.onMove)
            window.removeEventListener("pointerup", this.onUp)
            window.removeEventListener("keydown", this.onKey)
            const scroller = document.getElementById("canvas-scroll")
            if (scroller) scroller.removeEventListener("wheel", this.onWheel)
          }
        }
      </script>
    </Layouts.console>
    """
  end

  # `<% node = ... %>` bindings don't survive across sibling attribute
  # expressions; expose the lookup as a render helper instead.
  defp selected_node_assign(graph, selected_id), do: find_node(graph, selected_id)
end
