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
    },
    "document_extractor" => %{
      label: "Doc Extractor",
      icon: "hero-document-text",
      accent: "bg-neutral/10 text-neutral"
    },
    "iteration" => %{
      label: "Iteration",
      icon: "hero-arrow-path-rounded-square",
      accent: "bg-primary/10 text-primary"
    },
    "loop" => %{
      label: "Loop",
      icon: "hero-arrow-uturn-left",
      accent: "bg-primary/10 text-primary"
    },
    "human_input" => %{
      label: "Human Input",
      icon: "hero-hand-raised",
      accent: "bg-warning/10 text-warning"
    },
    "knowledge_retrieval" => %{
      label: "Knowledge",
      icon: "hero-book-open",
      accent: "bg-success/10 text-success"
    },
    "document" => %{
      label: "Document",
      icon: "hero-document-arrow-down",
      accent: "bg-accent/10 text-accent"
    },
    "interview" => %{
      label: "Interview",
      icon: "hero-clipboard-document-check",
      accent: "bg-warning/10 text-warning"
    }
  }

  @node_desc %{
    "start" => "Where every run begins: declares the input variables the flux expects.",
    "llm" =>
      "Calls an AI model with your prompt and streams the reply. Supports structured output and a fallback model.",
    "if_else" => "Routes the run down different branches based on conditions (if / elif / else).",
    "template" =>
      "Renders text from your variables: simple {{refs}}, full Jinja, or a saved doc template.",
    "answer" => "Streams the user-facing reply in chats. Interpolate anything the flux computed.",
    "end" => "Maps the flux's final outputs: what API callers and parent fluxes receive.",
    "tool" => "Calls one operation of an imported API toolset or an installed tool plugin.",
    "http_request" =>
      "Calls an external HTTP API (SSRF-guarded). Outputs status, parsed body, and raw text.",
    "code" => "Runs a code snippet in the sandboxed runner; the returned keys become outputs.",
    "agent" =>
      "An autonomous loop: the model picks tools and iterates until it is done or hits the cap.",
    "variable_aggregator" =>
      "Takes the first non-empty of several sources, merging branches back into one variable.",
    "variable_assigner" =>
      "Writes conversation variables that persist across a chatflow's turns.",
    "list_operator" => "Filters, sorts, and slices a list from the variable pool without code.",
    "question_classifier" =>
      "Asks the model to classify the input; the run continues on that class's branch.",
    "parameter_extractor" => "Asks the model to pull structured parameters out of free text.",
    "document_extractor" => "Turns an uploaded file into plain text for downstream nodes.",
    "iteration" => "Runs a published sub-flux once per item of a list and collects the results.",
    "loop" => "Repeats a published sub-flux until a break condition matches (a bounded while).",
    "human_input" => "Pauses the run and asks a person; it resumes with their reply.",
    "knowledge_retrieval" =>
      "Searches your knowledge datasets (hybrid retrieval) and returns the best passages with citations.",
    "document" =>
      "Fills a Word doc template with your variables and outputs the finished file for download.",
    "interview" =>
      "Pauses the run and asks a stored question set as one form; answers land in the pool."
  }

  @addable_types ~w(llm knowledge_retrieval if_else question_classifier parameter_extractor
                    document_extractor iteration loop human_input interview template document
                    tool http_request code agent variable_aggregator variable_assigner
                    list_operator answer end)
  @zoom_levels [50, 65, 80, 100, 125, 150]
  @failable_types ~w(llm tool http_request code agent question_classifier parameter_extractor
                     document_extractor iteration loop knowledge_retrieval document)
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
           doc_templates: Flux.DocTemplates.list(scope),
           interviews: Flux.Interviews.list(scope),
           resume_errors: %{},
           models: Providers.available_models(scope),
           toolsets:
             Flux.Tools.list_toolsets(scope) ++ Flux.Tools.installed_plugin_toolsets(scope),
           fluxes: Workflows.list_workflows(scope),
           datasets: Flux.RAG.list_datasets(scope),
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
           agent_activity: [],
           show_api: false,
           tokens: [],
           new_token_raw: nil,
           show_triggers: false,
           triggers: [],
           trigger_type: "webhook",
           trigger_plugins: [],
           show_site: false,
           show_versions: false,
           versions: [],
           show_variables: false,
           env_rows: [],
           conv_rows: [],
           clipboard: nil,
           palette_query: "",
           node_debug: nil,
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

  def handle_event("palette_search", %{"palette_query" => query}, socket) do
    {:noreply, assign(socket, palette_query: query)}
  end

  def handle_event("auto_layout", _params, socket) do
    if socket.assigns.can_edit do
      update_graph(socket, &auto_layout/1)
    else
      {:noreply, socket}
    end
  end

  def handle_event("copy_selection", _params, socket) do
    graph = socket.assigns.graph

    ids =
      case {socket.assigns.selected_ids, socket.assigns.selected_id} do
        {[_ | _] = many, _single} -> many
        {_none, id} when is_binary(id) -> [id]
        _nothing -> []
      end

    nodes =
      Enum.filter(graph["nodes"] || [], &(&1["id"] in ids and &1["type"] != "start"))

    node_ids = MapSet.new(nodes, & &1["id"])

    edges =
      Enum.filter(graph["edges"] || [], fn edge ->
        MapSet.member?(node_ids, edge["source"]) and MapSet.member?(node_ids, edge["target"])
      end)

    if nodes == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, clipboard: %{nodes: nodes, edges: edges})}
    end
  end

  def handle_event("paste_clipboard", _params, socket) do
    case socket.assigns.clipboard do
      %{nodes: nodes, edges: edges} when nodes != [] ->
        graph = socket.assigns.graph

        # Mint fresh ids one at a time so pasted siblings can't collide.
        {id_map, new_nodes} =
          Enum.reduce(nodes, {%{}, []}, fn node, {id_map, acc} ->
            scratch = Map.update(graph, "nodes", acc, &(&1 ++ acc))
            new_id = unique_node_id(scratch, node["type"])

            copy =
              node
              |> Map.put("id", new_id)
              |> Map.put("position", %{
                "x" => node_x(node) + 32,
                "y" => node_y(node) + 32
              })

            {Map.put(id_map, node["id"], new_id), acc ++ [copy]}
          end)

        new_edges =
          Enum.map(edges, fn edge ->
            source = Map.fetch!(id_map, edge["source"])
            target = Map.fetch!(id_map, edge["target"])

            %{
              "id" => "edge_#{source}_#{edge["source_handle"]}_#{target}",
              "source" => source,
              "source_handle" => edge["source_handle"],
              "target" => target
            }
          end)

        socket = set_selection(socket, Enum.map(new_nodes, & &1["id"]))

        update_graph(socket, fn graph ->
          graph
          |> Map.update("nodes", new_nodes, &(&1 ++ new_nodes))
          |> Map.update("edges", new_edges, &(&1 ++ new_edges))
        end)

      _empty ->
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

  def handle_event("resume_run", params, socket) do
    with %{status: :paused} = run <- socket.assigns.run,
         {:ok, resumed} <-
           Workflows.resume_run_with_params(socket.assigns.current_scope, run.id, params) do
      {:noreply, assign(socket, run: resumed, resume_errors: %{})}
    else
      {:error, {:invalid_answers, errors}} ->
        {:noreply, assign(socket, resume_errors: errors)}

      _not_paused_or_error ->
        {:noreply, put_flash(socket, :error, "Could not resume the run.")}
    end
  end

  def handle_event("debug_node", params, socket) do
    node = selected_node(socket)

    if node && socket.assigns.can_run do
      result =
        Workflows.debug_node(
          socket.assigns.current_scope,
          socket.assigns.workflow,
          node["id"],
          params["mock"] || %{}
        )

      {:noreply, assign(socket, node_debug: result)}
    else
      {:noreply, socket}
    end
  end

  ## Multi-case if-else editing

  def handle_event("add_case", _params, socket) do
    update_if_else(socket, fn cases ->
      taken = MapSet.new(cases, & &1["id"])

      new_id =
        Enum.find(Stream.map(1..1_000, &"case_#{&1}"), &(not MapSet.member?(taken, &1)))

      cases ++
        [
          %{
            "id" => new_id,
            "logical_operator" => "and",
            "conditions" => [empty_row("condition")]
          }
        ]
    end)
  end

  def handle_event("remove_case", %{"index" => index}, socket) do
    index = String.to_integer(index)

    with %{"type" => "if_else"} = node <- selected_node(socket) do
      removed = Enum.at(if_else_cases(node["config"]), index)

      update_graph(socket, fn graph ->
        graph
        |> update_node_in(node["id"], fn current ->
          cases = List.delete_at(if_else_cases(current["config"]), index)

          Map.put(
            current,
            "config",
            current["config"]
            |> Map.put("cases", cases)
            |> Map.drop(["logical_operator", "conditions"])
          )
        end)
        |> Map.update("edges", [], fn edges ->
          Enum.reject(edges, fn edge ->
            edge["source"] == node["id"] and removed != nil and
              edge["source_handle"] == removed["id"]
          end)
        end)
      end)
    else
      _not_if_else -> {:noreply, socket}
    end
  end

  def handle_event("add_case_cond", %{"case-index" => index}, socket) do
    index = String.to_integer(index)

    update_if_else(socket, fn cases ->
      List.update_at(cases, index, fn kase ->
        Map.update(
          kase,
          "conditions",
          [empty_row("condition")],
          &(&1 ++ [empty_row("condition")])
        )
      end)
    end)
  end

  def handle_event("remove_case_cond", %{"case-index" => case_index, "index" => index}, socket) do
    case_index = String.to_integer(case_index)
    index = String.to_integer(index)

    update_if_else(socket, fn cases ->
      List.update_at(cases, case_index, fn kase ->
        Map.update(kase, "conditions", [], &List.delete_at(&1, index))
      end)
    end)
  end

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
    {:noreply,
     assign(socket,
       show_run: false,
       node_states: %{},
       run: nil,
       run_text: "",
       agent_activity: []
     )}
  end

  def handle_event("start_run", params, socket) do
    if socket.assigns.can_run do
      scope = socket.assigns.current_scope
      inputs = Map.get(params, "inputs", %{})

      case Workflows.start_run(scope, socket.assigns.workflow, inputs) do
        {:ok, run} ->
          {:noreply, assign(socket, run: run, node_states: %{}, run_text: "", agent_activity: [])}

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

  ## Env + conversation variables

  def handle_event("toggle_variables", _params, socket) do
    graph = socket.assigns.graph

    env_rows =
      graph
      |> Map.get("env", %{})
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)

    {:noreply,
     assign(socket,
       show_variables: not socket.assigns.show_variables,
       env_rows: env_rows,
       conv_rows: List.wrap(graph["conversation_variables"])
     )}
  end

  def handle_event("variables_change", params, socket) do
    {:noreply,
     assign(socket,
       env_rows: indexed_rows(params["envs"], ~w(key value), %{}),
       conv_rows: indexed_rows(params["convs"], ~w(name default), %{})
     )}
  end

  def handle_event("add_env_row", _params, socket) do
    {:noreply,
     assign(socket, env_rows: socket.assigns.env_rows ++ [%{"key" => "", "value" => ""}])}
  end

  def handle_event("add_conv_row", _params, socket) do
    {:noreply,
     assign(socket, conv_rows: socket.assigns.conv_rows ++ [%{"name" => "", "default" => ""}])}
  end

  def handle_event("remove_env_row", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       env_rows: List.delete_at(socket.assigns.env_rows, String.to_integer(index))
     )}
  end

  def handle_event("remove_conv_row", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       conv_rows: List.delete_at(socket.assigns.conv_rows, String.to_integer(index))
     )}
  end

  def handle_event("save_variables", params, socket) do
    env =
      params["envs"]
      |> indexed_rows(~w(key value), %{})
      |> Enum.reject(&(&1["key"] == ""))
      |> Map.new(fn row -> {row["key"], row["value"]} end)

    conversation_variables =
      params["convs"]
      |> indexed_rows(~w(name default), %{})
      |> Enum.reject(&(&1["name"] == ""))

    socket =
      update_graph(socket, fn graph ->
        graph
        |> Map.put("env", env)
        |> Map.put("conversation_variables", conversation_variables)
      end)
      |> elem(1)

    {:noreply, socket |> assign(show_variables: false) |> put_flash(:info, "Variables saved.")}
  end

  ## Versions

  def handle_event("toggle_versions", _params, socket) do
    versions =
      if socket.assigns.show_versions do
        []
      else
        Workflows.list_versions(socket.assigns.current_scope, socket.assigns.workflow.id)
      end

    {:noreply,
     assign(socket, show_versions: not socket.assigns.show_versions, versions: versions)}
  end

  def handle_event("restore_version", %{"version" => version}, socket) do
    with true <- socket.assigns.can_edit,
         %{graph: graph} <-
           Workflows.get_version(
             socket.assigns.current_scope,
             socket.assigns.workflow.id,
             String.to_integer(version)
           ) do
      # Restoring goes through update_graph, so undo brings the draft back.
      socket = assign(socket, show_versions: false)
      {:noreply, updated} = update_graph(socket, fn _draft -> graph end)

      {:noreply,
       put_flash(updated, :info, "Draft replaced with v#{version} — publish to ship it.")}
    else
      _cannot_restore -> {:noreply, put_flash(socket, :error, "Could not restore that version.")}
    end
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

  def handle_event("save_site_theme", params, socket) do
    theme =
      %{
        "accent" => params["accent"],
        "title" => params["title"],
        "logo_url" => params["logo_url"]
      }
      |> Enum.map(fn {key, value} -> {key, String.trim(to_string(value))} end)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Map.new()

    case Workflows.set_site_theme(socket.assigns.current_scope, socket.assigns.workflow, theme) do
      {:ok, workflow} ->
        {:noreply, socket |> assign(workflow: workflow) |> put_flash(:info, "Theme saved.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the theme.")}
    end
  end

  ## Triggers

  def handle_event("toggle_triggers", _params, socket) do
    scope = socket.assigns.current_scope
    installed = MapSet.new(Flux.Tools.list_installed_plugin_ids(scope))

    trigger_plugins =
      Enum.filter(plugin_runtime().list_trigger_plugins(), &MapSet.member?(installed, &1.id))

    {:noreply,
     assign(socket,
       show_triggers: not socket.assigns.show_triggers,
       trigger_type: "webhook",
       trigger_plugins: trigger_plugins,
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
             "cron" => params["cron"],
             "plugin_id" => params["plugin_id"],
             "webhook_secret" => params["webhook_secret"],
             "inputs" => inputs
           }) do
      {:noreply,
       assign(socket, triggers: Workflows.list_triggers(scope, socket.assigns.workflow.id))}
    else
      {:error, :bad_json} ->
        {:noreply, put_flash(socket, :error, "Static inputs must be a JSON object.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage triggers.")}

      {:error, :plugin_not_installed} ->
        {:noreply, put_flash(socket, :error, "Install that plugin first (Plugins page).")}

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

  # Agent inner-loop activity: thinking deltas fold into the latest
  # thought entry; tool calls/results append discrete entries.
  def handle_info({:engine_event, {:agent_part, part}}, socket) do
    activity =
      case part do
        %{type: "part_start"} ->
          socket.assigns.agent_activity ++
            [%{kind: :thought, iteration: part.iteration, text: ""}]

        %{type: "part_delta", delta: delta} ->
          case List.last(socket.assigns.agent_activity) do
            %{kind: :thought} = thought ->
              List.replace_at(
                socket.assigns.agent_activity,
                -1,
                %{thought | text: thought.text <> delta}
              )

            _no_thought_open ->
              socket.assigns.agent_activity ++
                [%{kind: :thought, iteration: part.iteration, text: delta}]
          end

        %{type: "function_tool_call"} ->
          socket.assigns.agent_activity ++
            [
              %{
                kind: :tool_call,
                iteration: part.iteration,
                name: part.name,
                arguments: part[:arguments] || %{}
              }
            ]

        %{type: "function_tool_result"} ->
          socket.assigns.agent_activity ++
            [
              %{
                kind: :tool_result,
                iteration: part.iteration,
                name: part.name,
                content: String.slice(part[:content] || "", 0, 400)
              }
            ]

        _other ->
          socket.assigns.agent_activity
      end

    {:noreply, assign(socket, agent_activity: Enum.take(activity, -60))}
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

  # Hard build errors plus advisory reference lint (typo'd {{refs}} render
  # empty at run time — worth a warning, never a block).
  defp issues(graph) do
    build_errors =
      case Engine.build(graph) do
        {:ok, _graph} -> []
        {:error, errors} -> errors
      end

    warnings = Enum.map(Flux.Engine.Lint.reference_warnings(graph), &("warning: " <> &1))
    build_errors ++ warnings
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
      selected_edge: edge,
      node_debug: nil
    )
  end

  # Every {{selector}} referenced anywhere in a node's config (recursively),
  # so the debug panel can offer a mock input per upstream value.
  defp config_references(node) do
    node["config"]
    |> collect_strings()
    |> Enum.flat_map(fn text ->
      ~r/\{\{\s*([\w\-\.]+)\s*\}\}/
      |> Regex.scan(text)
      |> Enum.map(fn [_whole, path] -> path end)
    end)
    |> Enum.uniq()
  end

  defp collect_strings(value) when is_binary(value), do: [value]
  defp collect_strings(value) when is_map(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings({_key, value}), do: collect_strings(value)
  defp collect_strings(_other), do: []

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

  # Retry settings apply to every failable node type, so they merge in
  # after the type-specific config is built.
  defp put_retry(config, %{"max_retries" => max_retries}) do
    case Integer.parse(to_string(max_retries)) do
      {n, ""} when n > 0 -> Map.put(config, "retry", %{"max_retries" => min(n, 5)})
      _off -> Map.delete(config, "retry")
    end
  end

  defp put_retry(config, _params), do: config

  defp filtered_palette(""), do: @addable_types

  defp filtered_palette(query) do
    needle = String.downcase(query)

    Enum.filter(@addable_types, fn type ->
      String.contains?(String.downcase(@node_meta[type].label), needle) or
        String.contains?(type, needle)
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

  defp default_config("document_extractor"), do: %{"variable" => ""}

  defp default_config("iteration"),
    do: %{"variable" => "", "workflow_id" => "", "max_items" => 50}

  defp default_config("loop"),
    do: %{
      "workflow_id" => "",
      "initial" => "",
      "max_loops" => 5,
      "logical_operator" => "and",
      "conditions" => []
    }

  defp default_config("human_input"),
    do: %{"prompt" => "Please review and reply:", "options" => []}

  defp default_config("knowledge_retrieval"),
    do: %{"dataset_id" => "", "query" => "{{start.query}}", "top_k" => 4}

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

    {fallback_plugin, fallback_model} =
      case String.split(Map.get(params, "fallback_choice", "keep"), "|", parts: 2) do
        [fallback_plugin, fallback_model] -> {fallback_plugin, fallback_model}
        ["keep"] -> {config["fallback_provider_plugin_id"], config["fallback_model"]}
        _cleared -> {"", ""}
      end

    %{
      "provider_plugin_id" => plugin_id,
      "model" => model,
      "fallback_provider_plugin_id" => fallback_plugin,
      "fallback_model" => fallback_model,
      "system_prompt" => Map.get(params, "system_prompt", ""),
      "prompt" => Map.get(params, "prompt", ""),
      "output_schema" => parse_output_schema(params["output_schema"], config["output_schema"])
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
    case params["case"] do
      %{} = case_params ->
        cases =
          case_params
          |> Enum.sort_by(fn {index, _kase} -> String.to_integer(index) end)
          |> Enum.map(fn {_index, kase} ->
            %{
              "id" => to_string(kase["id"] || ""),
              "logical_operator" => kase["logical_operator"] || "and",
              "conditions" => indexed_rows(kase["conds"], ~w(left operator right), %{})
            }
          end)

        config
        |> Map.put("cases", cases)
        |> Map.drop(["logical_operator", "conditions"])

      _no_case_params ->
        config
        |> Map.put("logical_operator", Map.get(params, "logical_operator", "and"))
        |> Map.put("conditions", indexed_rows(params["conds"], ~w(left operator right), %{}))
    end
  end

  defp build_config("template", config, params) do
    config
    |> Map.put("template", Map.get(params, "template", ""))
    |> Map.put("engine", Map.get(params, "engine", config["engine"] || "simple"))
    |> Map.put("template_id", Map.get(params, "template_id", config["template_id"] || ""))
  end

  defp build_config("document", config, params) do
    config
    |> Map.put("template_id", Map.get(params, "template_id", config["template_id"] || ""))
    |> Map.put("output_name", Map.get(params, "output_name", config["output_name"] || ""))
    |> Map.put(
      "output_format",
      Map.get(params, "output_format", config["output_format"] || "docx")
    )
  end

  defp build_config("interview", config, params) do
    config
    |> Map.put("interview_id", Map.get(params, "interview_id", config["interview_id"] || ""))
    |> Map.put("intro", Map.get(params, "intro", config["intro"] || ""))
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
      "enable_drive" =>
        Map.get(params, "enable_drive", to_string(config["enable_drive"] == true)) == "true",
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

  defp build_config("document_extractor", config, params) do
    Map.put(config, "variable", Map.get(params, "variable", config["variable"] || ""))
  end

  defp build_config("human_input", config, params) do
    options =
      params
      |> Map.get("options_text", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config
    |> Map.put("prompt", Map.get(params, "prompt", config["prompt"] || ""))
    |> Map.put("options", options)
  end

  defp build_config("knowledge_retrieval", config, params) do
    top_k =
      case Integer.parse(to_string(Map.get(params, "top_k", ""))) do
        {n, ""} when n in 1..20 -> n
        _invalid -> config["top_k"] || 4
      end

    dataset_ids =
      case params["ds"] do
        %{} = checked ->
          for {dataset_id, "true"} <- checked, do: dataset_id

        _no_checkboxes ->
          knowledge_dataset_ids(config)
      end

    config
    |> Map.put("dataset_ids", dataset_ids)
    |> Map.delete("dataset_id")
    |> Map.put("query", Map.get(params, "query", config["query"] || ""))
    |> Map.put("top_k", top_k)
  end

  defp build_config("iteration", config, params) do
    max_items =
      case Integer.parse(to_string(Map.get(params, "max_items", ""))) do
        {n, ""} when n in 1..200 -> n
        _invalid -> config["max_items"] || 50
      end

    config
    |> Map.put("variable", Map.get(params, "variable", config["variable"] || ""))
    |> Map.put("workflow_id", Map.get(params, "workflow_id", config["workflow_id"] || ""))
    |> Map.put("max_items", max_items)
  end

  defp build_config("loop", config, params) do
    max_loops =
      case Integer.parse(to_string(Map.get(params, "max_loops", ""))) do
        {n, ""} when n in 1..100 -> n
        _invalid -> config["max_loops"] || 5
      end

    # One break condition from the panel; richer lists come in via DSL.
    conditions =
      case {Map.get(params, "break_left"), Map.get(params, "break_right")} do
        {nil, _right} ->
          config["conditions"] || []

        {left, right} ->
          if String.trim(to_string(left)) == "" do
            []
          else
            [
              %{
                "left" => left,
                "operator" => Map.get(params, "break_operator", "equals"),
                "right" => right || ""
              }
            ]
          end
      end

    config
    |> Map.put("workflow_id", Map.get(params, "workflow_id", config["workflow_id"] || ""))
    |> Map.put("initial", Map.get(params, "initial", config["initial"] || ""))
    |> Map.put("max_loops", max_loops)
    |> Map.put("logical_operator", "and")
    |> Map.put("conditions", conditions)
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

  defp knowledge_dataset_ids(config) do
    (List.wrap(config["dataset_ids"]) ++ List.wrap(config["dataset_id"]))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

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
  defp desc(type), do: Map.get(@node_desc, type, "")
  defp node_docs_href(type), do: ~p"/console/docs/node-reference" <> "#" <> type

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

  # Branch labels: named handles (true/false/case ids/error) render on
  # the wire so routing reads at a glance.
  defp edge_label_svg(assigns, edge) do
    case edge_label_at(assigns.graph, edge) do
      nil ->
        nil

      {x, y} ->
        assigns = Map.merge(assigns, %{label_x: x, label_y: y, label: edge["source_handle"]})

        ~H"""
        <text
          x={@label_x}
          y={@label_y}
          class={[
            "text-[10px] font-semibold uppercase tracking-wide",
            (@label == "error" && "fill-error") || "fill-current"
          ]}
          style="paint-order: stroke; stroke: var(--color-base-100); stroke-width: 3px;"
        >
          {@label}
        </text>
        """
    end
  end

  # Where a branch label sits: the bezier midpoint, biased toward the
  # source so parallel edges from one node stay readable.
  defp edge_label_at(graph, edge) do
    with %{} = source <- find_node(graph, edge["source"]),
         %{} = target <- find_node(graph, edge["target"]) do
      y_offset = source_handle_offset(source, edge["source_handle"])
      x1 = node_x(source) + @node_width
      y1 = node_y(source) + y_offset
      x2 = node_x(target)
      y2 = node_y(target) + @port_y
      {x1 + (x2 - x1) * 0.35, y1 + (y2 - y1) * 0.35 - 6}
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
    "llm" => ~w(text output),
    "template" => ~w(output),
    "answer" => ~w(answer),
    "tool" => ~w(text status body),
    "http_request" => ~w(text status_code body),
    "code" => ~w(stdout),
    "agent" => ~w(text output status iterations tool_calls),
    "variable_aggregator" => ~w(output),
    "list_operator" => ~w(output first last count),
    "question_classifier" => ~w(class_id class_name),
    "parameter_extractor" => ~w(is_success reason),
    "document_extractor" => ~w(text name size),
    "iteration" => ~w(output count),
    "loop" => ~w(output rounds condition_met),
    "human_input" => ~w(output),
    "knowledge_retrieval" => ~w(result citations count),
    "document" => ~w(url name file_id size),
    "interview" => ~w(output)
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

  # Layered left-to-right layout: column = longest path from start
  # (relaxation over the acyclic graph), row order preserves current y.
  defp auto_layout(graph) do
    nodes = graph["nodes"] || []
    edges = graph["edges"] || []
    start = Enum.find(nodes, &(&1["type"] == "start"))

    depths =
      Enum.reduce(1..max(length(nodes), 1), %{(start && start["id"]) => 0}, fn _pass, depths ->
        Enum.reduce(edges, depths, fn edge, depths ->
          case Map.fetch(depths, edge["source"]) do
            {:ok, depth} -> Map.update(depths, edge["target"], depth + 1, &max(&1, depth + 1))
            :error -> depths
          end
        end)
      end)

    max_depth = depths |> Map.values() |> Enum.max(fn -> 0 end)

    columns =
      nodes
      |> Enum.group_by(fn node -> Map.get(depths, node["id"], max_depth + 1) end)
      |> Enum.into(%{}, fn {depth, column} ->
        {depth, Enum.sort_by(column, &node_y/1)}
      end)

    positions =
      for {depth, column} <- columns,
          {node, row} <- Enum.with_index(column),
          into: %{} do
        {node["id"], %{"x" => 60 + depth * 300, "y" => 60 + row * 150}}
      end

    Map.update(graph, "nodes", [], fn nodes ->
      Enum.map(nodes, fn node ->
        Map.put(node, "position", Map.get(positions, node["id"], node["position"]))
      end)
    end)
  end

  defp update_if_else(socket, fun) do
    with %{"type" => "if_else"} = node <- selected_node(socket) do
      update_graph(socket, fn graph ->
        update_node_in(graph, node["id"], fn current ->
          cases = fun.(if_else_cases(current["config"]))

          Map.put(
            current,
            "config",
            current["config"]
            |> Map.put("cases", cases)
            |> Map.drop(["logical_operator", "conditions"])
          )
        end)
      end)
    else
      _not_if_else -> {:noreply, socket}
    end
  end

  defp if_else_cases(config), do: Flux.Engine.Nodes.IfElse.cases(config)

  # Bar width relative to the slowest node in the run (min 2% so instant
  # nodes stay visible).
  defp duration_percent(executions, execution) do
    slowest =
      executions
      |> Enum.map(&(&1["elapsed_ms"] || 0))
      |> Enum.max(fn -> 0 end)

    if slowest == 0 do
      2
    else
      max(round((execution["elapsed_ms"] || 0) / slowest * 100), 2)
    end
  end

  defp failable?(type), do: type in @failable_types

  defp format_debug_error(:unauthorized), do: "You don't have permission to run nodes."
  defp format_debug_error(:not_found), do: "Node not found."
  defp format_debug_error(message) when is_binary(message), do: message
  defp format_debug_error(other), do: inspect(other)

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

  defp source_handle_offset(%{"type" => "if_else"} = source, handle) do
    cases = if_else_cases(source["config"])

    case Enum.find_index(cases, &(&1["id"] == handle)) do
      nil -> @port_y + length(cases) * 28 - 2
      index -> @port_y + index * 28 - 2
    end
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

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

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
              <div
                tabindex="0"
                role="button"
                class="btn btn-sm btn-outline"
                title="Add a node to the canvas"
              >
                <.icon name="hero-plus" class="size-4" /> Add node
              </div>
              <div
                tabindex="0"
                class="dropdown-content bg-base-100 rounded-box z-20 w-56 p-2 shadow border border-base-200 space-y-1"
              >
                <form phx-change="palette_search" onsubmit="return false">
                  <input
                    type="text"
                    name="palette_query"
                    value={@palette_query}
                    placeholder="Search nodes…"
                    autocomplete="off"
                    class="input input-xs w-full"
                  />
                </form>
                <ul class="menu p-0 max-h-72 overflow-y-auto flex-nowrap">
                  <li :for={type <- filtered_palette(@palette_query)}>
                    <button phx-click="add_node" phx-value-type={type} title={desc(type)}>
                      <.icon name={meta(type).icon} class="size-4" /> {meta(type).label}
                    </button>
                  </li>
                </ul>
              </div>
            </div>
            <.link
              :if={@can_export}
              href={~p"/console/fluxes/#{@workflow.id}/export"}
              class="btn btn-sm btn-ghost"
              title="Download portable DSL"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Export
            </.link>
            <button
              :if={@can_edit}
              class="btn btn-sm btn-ghost"
              phx-click="auto_layout"
              title="Auto-arrange nodes left to right"
            >
              <.icon name="hero-rectangle-group" class="size-4" /> Tidy
            </button>
            <button
              class="btn btn-sm btn-ghost"
              phx-click="toggle_history"
              title="Browse past runs of this flux"
            >
              <.icon name="hero-clock" class="size-4" /> History
            </button>
            <button
              :if={@latest_version != nil}
              class="btn btn-sm btn-ghost"
              phx-click="toggle_versions"
              title="Published versions: view or roll back"
            >
              <.icon name="hero-archive-box" class="size-4" /> Versions
            </button>
            <button
              :if={@can_manage_tokens}
              class="btn btn-sm btn-ghost"
              phx-click="toggle_api"
              title="Service tokens and API call snippets"
            >
              <.icon name="hero-key" class="size-4" /> API
            </button>
            <button
              :if={@can_edit}
              class="btn btn-sm btn-ghost"
              phx-click="toggle_variables"
              title="Environment and conversation variables"
            >
              <.icon name="hero-variable" class="size-4" /> Variables
            </button>
            <button
              :if={@can_edit}
              class="btn btn-sm btn-ghost"
              phx-click="toggle_triggers"
              title="Webhooks and schedules that start this flux"
            >
              <.icon name="hero-bolt" class="size-4" /> Triggers
            </button>
            <button
              :if={@can_manage_tokens}
              class="btn btn-sm btn-ghost"
              phx-click="toggle_site"
              title="Publish a public form page for this flux"
            >
              <.icon name="hero-globe-alt" class="size-4" /> Site
            </button>
            <button
              :if={@can_publish}
              class="btn btn-sm btn-outline"
              phx-click="publish"
              title="Snapshot the draft as the live version"
            >
              <.icon name="hero-rocket-launch" class="size-4" /> Publish
            </button>
            <button
              :if={@can_run}
              class="btn btn-sm btn-primary"
              phx-click="open_run"
              title="Run the current draft"
            >
              <.icon name="hero-play" class="size-4" /> Run
            </button>
          </div>
        </div>

        <div class="flex flex-1 min-h-0 gap-3">
          <div class="flex-1 min-w-0 relative rounded-box border border-base-300 bg-base-200/40">
            <div
              id="minimap"
              phx-hook=".Minimap"
              class="absolute bottom-3 right-3 z-10 rounded-box border border-base-300 bg-base-100/90 shadow overflow-hidden cursor-pointer"
              style="width: 176px; height: 96px;"
              title="Minimap — click to jump"
            >
              <svg viewBox="0 0 3000 1600" preserveAspectRatio="none" class="w-full h-full">
                <rect
                  :for={node <- @graph["nodes"] || []}
                  x={node_x(node)}
                  y={node_y(node)}
                  width="208"
                  height="90"
                  rx="20"
                  class={
                    (node["id"] in @selected_ids && "fill-primary") ||
                      "fill-base-content opacity-40"
                  }
                />
                <rect
                  id="minimap-viewport"
                  fill="none"
                  class="stroke-primary"
                  stroke-width="40"
                  x="0"
                  y="0"
                  width="0"
                  height="0"
                />
              </svg>
            </div>
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
                      {if edge["source_handle"] not in [nil, "", "default"],
                        do: edge_label_svg(assigns, edge)}
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
                  title={"#{meta(node["type"]).label} — #{desc(node["type"])}"}
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
                    <a
                      data-docs-link
                      href={node_docs_href(node["type"])}
                      target="_blank"
                      class="ml-auto shrink-0 opacity-40 hover:opacity-100"
                      title={"#{meta(node["type"]).label}: #{desc(node["type"])} Click for the docs."}
                    >
                      <.icon name="hero-question-mark-circle" class="size-4" />
                    </a>
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
                      :for={{kase, index} <- Enum.with_index(if_else_cases(node["config"]))}
                      data-out-port
                      data-node-id={node["id"]}
                      data-handle={kase["id"]}
                      class="absolute -right-1.5 size-3 rounded-full bg-success hover:scale-125 transition-transform cursor-crosshair"
                      style={"top: #{22 + index * 28}px"}
                      title={"Case: #{kase["id"]}"}
                    >
                    </span>
                    <span
                      data-out-port
                      data-node-id={node["id"]}
                      data-handle="false"
                      class="absolute -right-1.5 size-3 rounded-full bg-error hover:scale-125 transition-transform cursor-crosshair"
                      style={"top: #{22 + length(if_else_cases(node["config"])) * 28}px"}
                      title="ELSE branch"
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

            <p class="text-xs opacity-70">
              {desc(node["type"])}
              <a
                href={node_docs_href(node["type"])}
                target="_blank"
                class="link link-primary whitespace-nowrap"
                title={"Open the node reference for #{meta(node["type"]).label} in a new tab"}
              >
                Docs <.icon name="hero-arrow-top-right-on-square" class="size-3 inline" />
              </a>
            </p>

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
                    <span>Fallback model (tried when the primary errors)</span>
                    <select
                      name="fallback_choice"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["fallback_model"] in [nil, ""]}>
                        No fallback
                      </option>
                      <option
                        :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
                        value={"#{pid}|#{m.name}"}
                        selected={
                          node["config"]["fallback_provider_plugin_id"] == pid and
                            node["config"]["fallback_model"] == m.name
                        }
                      >
                        {pname} — {m.label}
                      </option>
                    </select>
                  </label>
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
                  <label class="floating-label">
                    <span>
                      Output schema (JSON, optional — adds a structured {"{{node.output}}"} )
                    </span>
                    <textarea
                      name="output_schema"
                      rows="3"
                      class="textarea textarea-sm w-full font-mono"
                      placeholder={~s({"type": "object", "properties": {...}})}
                      disabled={not @can_edit}
                    >{node["config"]["output_schema"] && Jason.encode!(node["config"]["output_schema"])}</textarea>
                  </label>
                <% "if_else" -> %>
                  <div
                    :for={{kase, case_index} <- Enum.with_index(if_else_cases(node["config"]))}
                    class="rounded-box border border-base-300 p-2 space-y-2"
                  >
                    <div class="flex items-center gap-2">
                      <span class="badge badge-warning badge-sm">
                        {(case_index == 0 && "IF") || "ELIF"} · {kase["id"]}
                      </span>
                      <input type="hidden" name={"case[#{case_index}][id]"} value={kase["id"]} />
                      <select
                        name={"case[#{case_index}][logical_operator]"}
                        class="select select-xs w-20"
                        disabled={not @can_edit}
                      >
                        <option value="and" selected={kase["logical_operator"] != "or"}>AND</option>
                        <option value="or" selected={kase["logical_operator"] == "or"}>OR</option>
                      </select>
                      <button
                        :if={length(if_else_cases(node["config"])) > 1}
                        type="button"
                        class="btn btn-ghost btn-xs text-error ml-auto"
                        phx-click="remove_case"
                        phx-value-index={case_index}
                        disabled={not @can_edit}
                        data-confirm="Remove this case (its edge is removed too)?"
                      >
                        ✕
                      </button>
                    </div>
                    <div
                      :for={{condition, index} <- Enum.with_index(List.wrap(kase["conditions"]))}
                      class="rounded-box border border-base-200 p-2 space-y-2"
                    >
                      <input
                        type="text"
                        name={"case[#{case_index}][conds][#{index}][left]"}
                        value={condition["left"]}
                        placeholder="{{start.query}}"
                        class="input input-xs w-full"
                        disabled={not @can_edit}
                      />
                      <div class="flex gap-2">
                        <select
                          name={"case[#{case_index}][conds][#{index}][operator]"}
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
                          phx-click="remove_case_cond"
                          phx-value-case-index={case_index}
                          phx-value-index={index}
                          disabled={not @can_edit}
                        >
                          ✕
                        </button>
                      </div>
                      <input
                        type="text"
                        name={"case[#{case_index}][conds][#{index}][right]"}
                        value={condition["right"]}
                        placeholder="value"
                        class="input input-xs w-full"
                        disabled={not @can_edit}
                      />
                    </div>
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="add_case_cond"
                      phx-value-case-index={case_index}
                      disabled={not @can_edit}
                    >
                      <.icon name="hero-plus" class="size-3" /> Add condition
                    </button>
                  </div>
                  <button
                    type="button"
                    class="btn btn-outline btn-xs"
                    phx-click="add_case"
                    disabled={not @can_edit}
                  >
                    <.icon name="hero-plus" class="size-3" /> Add ELIF case
                  </button>
                  <p class="text-xs opacity-60">
                    Unmatched input leaves on the red ELSE port.
                  </p>
                <% "template" -> %>
                  <label class="floating-label">
                    <span>Saved doc template (overrides the inline text)</span>
                    <select
                      name="template_id"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["template_id"] in [nil, ""]}>
                        None — use the inline template below
                      </option>
                      <option
                        :for={doc_template <- Enum.filter(@doc_templates, &(&1.kind != "docx"))}
                        value={doc_template.id}
                        selected={node["config"]["template_id"] == doc_template.id}
                      >
                        {doc_template.name}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Engine (inline template only)</span>
                    <select name="engine" class="select select-sm w-44" disabled={not @can_edit}>
                      <option value="simple" selected={node["config"]["engine"] in [nil, "simple"]}>
                        Simple {"{{node.key}}"}
                      </option>
                      <option value="jinja" selected={node["config"]["engine"] == "jinja"}>
                        Jinja (filters, if, for)
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Template</span>
                    <textarea
                      name="template"
                      rows="6"
                      class="textarea textarea-sm w-full font-mono"
                      disabled={not @can_edit}
                    >{node["config"]["template"]}</textarea>
                  </label>
                <% "document" -> %>
                  <label class="floating-label">
                    <span>Word template (upload one under Doc templates)</span>
                    <select
                      name="template_id"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["template_id"] in [nil, ""]}>
                        Choose a Word template…
                      </option>
                      <option
                        :for={doc_template <- Enum.filter(@doc_templates, &(&1.kind == "docx"))}
                        value={doc_template.id}
                        selected={node["config"]["template_id"] == doc_template.id}
                      >
                        {doc_template.name}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Output filename (templated, optional)</span>
                    <input
                      type="text"
                      name="output_name"
                      value={node["config"]["output_name"]}
                      placeholder="Engagement letter - {{start.client_name}}"
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <label class="floating-label">
                    <span>Output format</span>
                    <select
                      name="output_format"
                      class="select select-sm w-52"
                      disabled={not @can_edit}
                    >
                      <option
                        value="docx"
                        selected={node["config"]["output_format"] in [nil, "", "docx"]}
                      >
                        Word (.docx)
                      </option>
                      <option value="pdf" selected={node["config"]["output_format"] == "pdf"}>
                        PDF (needs FLUX_PDF_URL)
                      </option>
                    </select>
                  </label>
                  <p class="text-xs opacity-60">
                    Fills the template with this run's variables; downstream nodes see
                    <code>{"{{#{node["id"]}.url}}"}</code>
                    and <code>{"{{#{node["id"]}.name}}"}</code>.
                  </p>
                <% "interview" -> %>
                  <label class="floating-label">
                    <span>Interview (define them under Interviews)</span>
                    <select
                      name="interview_id"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["interview_id"] in [nil, ""]}>
                        Choose an interview…
                      </option>
                      <option
                        :for={interview <- @interviews}
                        value={interview.id}
                        selected={node["config"]["interview_id"] == interview.id}
                      >
                        {interview.name}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Intro override (templated, optional)</span>
                    <input
                      type="text"
                      name="intro"
                      value={node["config"]["intro"]}
                      placeholder="A few questions about {{start.matter}}…"
                      class="input input-sm w-full"
                      disabled={not @can_edit}
                    />
                  </label>
                  <p class="text-xs opacity-60">
                    The run pauses here and asks the questions as one form; each answer
                    lands as <code>{"{{#{node["id"]}.<name>}}"}</code>.
                  </p>
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
                  <label class="flex items-center gap-2 text-sm">
                    <input type="hidden" name="enable_drive" value="false" />
                    <input
                      type="checkbox"
                      name="enable_drive"
                      value="true"
                      checked={node["config"]["enable_drive"] == true}
                      class="checkbox checkbox-sm"
                      disabled={not @can_edit}
                    />
                    <span>
                      Scratch drive — the agent can save and re-read files during the run
                      ({"{{node.files}}"} output)
                    </span>
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
                <% "human_input" -> %>
                  <label class="floating-label">
                    <span>Prompt shown to the human</span>
                    <textarea
                      name="prompt"
                      rows="2"
                      class="textarea textarea-sm w-full"
                      disabled={not @can_edit}
                    >{node["config"]["prompt"]}</textarea>
                  </label>
                  <label class="floating-label">
                    <span>Suggested answers (comma-separated, optional)</span>
                    <input
                      type="text"
                      name="options_text"
                      value={Enum.join(List.wrap(node["config"]["options"]), ", ")}
                      placeholder="approve, reject"
                      class="input input-sm w-full"
                      disabled={not @can_edit}
                    />
                  </label>
                  <p class="text-xs opacity-60">
                    The run pauses here; the reply continues it as <code>{"{{#{node["id"]}.output}}"}</code>.
                  </p>
                <% "knowledge_retrieval" -> %>
                  <div class="space-y-1">
                    <p class="text-xs font-semibold opacity-70">Datasets</p>
                    <p :if={@datasets == []} class="text-xs text-warning">
                      No datasets yet — create one under Knowledge.
                    </p>
                    <label
                      :for={dataset <- @datasets}
                      class="flex items-center gap-2 text-sm"
                    >
                      <input type="hidden" name={"ds[#{dataset.id}]"} value="false" />
                      <input
                        type="checkbox"
                        name={"ds[#{dataset.id}]"}
                        value="true"
                        checked={dataset.id in knowledge_dataset_ids(node["config"])}
                        class="checkbox checkbox-xs"
                        disabled={not @can_edit}
                      />
                      {dataset.name}
                    </label>
                  </div>
                  <label class="floating-label">
                    <span>Query</span>
                    <input
                      type="text"
                      name="query"
                      value={node["config"]["query"]}
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <label class="floating-label">
                    <span>Top K (1–20)</span>
                    <input
                      type="number"
                      name="top_k"
                      value={node["config"]["top_k"] || 4}
                      min="1"
                      max="20"
                      class="input input-sm w-24"
                      disabled={not @can_edit}
                    />
                  </label>
                <% "iteration" -> %>
                  <label class="floating-label">
                    <span>List variable (one sub-flux run per item)</span>
                    <input
                      type="text"
                      name="variable"
                      value={node["config"]["variable"]}
                      placeholder="code_1.items"
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <label class="floating-label">
                    <span>Sub-flux (published; sees {"{{sys.item}}"} / {"{{sys.index}}"})</span>
                    <select
                      name="workflow_id"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["workflow_id"] in [nil, ""]}>
                        Choose a flux…
                      </option>
                      <option
                        :for={flux <- @fluxes}
                        :if={flux.id != @workflow.id}
                        value={flux.id}
                        selected={node["config"]["workflow_id"] == flux.id}
                      >
                        {flux.name}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Max items (1–200)</span>
                    <input
                      type="number"
                      name="max_items"
                      value={node["config"]["max_items"] || 50}
                      min="1"
                      max="200"
                      class="input input-sm w-24"
                      disabled={not @can_edit}
                    />
                  </label>
                <% "loop" -> %>
                  <label class="floating-label">
                    <span>Sub-flux (published; sees {"{{sys.item}}"} / {"{{sys.index}}"})</span>
                    <select
                      name="workflow_id"
                      class="select select-sm w-full"
                      disabled={not @can_edit}
                    >
                      <option value="" selected={node["config"]["workflow_id"] in [nil, ""]}>
                        Choose a flux…
                      </option>
                      <option
                        :for={flux <- @fluxes}
                        :if={flux.id != @workflow.id}
                        value={flux.id}
                        selected={node["config"]["workflow_id"] == flux.id}
                      >
                        {flux.name}
                      </option>
                    </select>
                  </label>
                  <label class="floating-label">
                    <span>Initial item (template; round 1's {"{{sys.item}}"})</span>
                    <input
                      type="text"
                      name="initial"
                      value={node["config"]["initial"]}
                      placeholder="{{start.query}}"
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <label class="floating-label">
                    <span>Max rounds (1–100)</span>
                    <input
                      type="number"
                      name="max_loops"
                      value={node["config"]["max_loops"] || 5}
                      min="1"
                      max="100"
                      class="input input-sm w-24"
                      disabled={not @can_edit}
                    />
                  </label>
                  <div class="space-y-1">
                    <p class="text-xs opacity-70">
                      Break when (blank = always run max rounds; round outputs are {"{{#{node["id"]}.<key>}}"})
                    </p>
                    <div class="flex gap-1">
                      <input
                        type="text"
                        name="break_left"
                        value={get_in(node, ["config", "conditions", Access.at(0), "left"])}
                        placeholder={"{{#{node["id"]}.done}}"}
                        class="input input-sm flex-1 font-mono"
                        disabled={not @can_edit}
                      />
                      <select
                        name="break_operator"
                        class="select select-sm w-32"
                        disabled={not @can_edit}
                      >
                        <option
                          :for={op <- Flux.Engine.Nodes.IfElse.operators()}
                          value={op}
                          selected={
                            get_in(node, ["config", "conditions", Access.at(0), "operator"]) == op
                          }
                        >
                          {op}
                        </option>
                      </select>
                      <input
                        type="text"
                        name="break_right"
                        value={get_in(node, ["config", "conditions", Access.at(0), "right"])}
                        placeholder="true"
                        class="input input-sm w-28 font-mono"
                        disabled={not @can_edit}
                      />
                    </div>
                  </div>
                <% "document_extractor" -> %>
                  <label class="floating-label">
                    <span>File id variable (an uploaded-file id, e.g. from a start input)</span>
                    <input
                      type="text"
                      name="variable"
                      value={node["config"]["variable"]}
                      placeholder="start.file_id"
                      class="input input-sm w-full font-mono"
                      disabled={not @can_edit}
                    />
                  </label>
                  <p class="text-xs opacity-60">
                    Native formats: text, markdown, CSV, JSON, HTML. Office formats
                    need the Tika sidecar (Docker stack).
                  </p>
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

            <div
              :if={@can_run and node["type"] != "start"}
              class="border-t border-base-200 pt-3 space-y-2"
              id="node-debug"
            >
              <p class="text-xs font-semibold opacity-70">Test this node</p>
              <form phx-submit="debug_node" class="space-y-2">
                <div :for={reference <- config_references(node)} class="flex items-center gap-2">
                  <code class="text-xs font-mono opacity-70 w-32 truncate" title={reference}>
                    {reference}
                  </code>
                  <input
                    type="text"
                    name={"mock[#{reference}]"}
                    placeholder="mock value"
                    class="input input-xs flex-1"
                  />
                </div>
                <button class="btn btn-outline btn-xs">
                  <.icon name="hero-beaker" class="size-3" /> Run node
                </button>
              </form>
              <div :if={@node_debug != nil}>
                <%= case @node_debug do %>
                  <% {:ok, outputs} -> %>
                    <pre class="rounded bg-base-200 p-2 text-xs overflow-x-auto max-h-48">{Jason.encode!(outputs, pretty: true)}</pre>
                  <% {:error, message} -> %>
                    <p class="text-xs text-error">{format_debug_error(message)}</p>
                <% end %>
              </div>
            </div>

            <div :if={variable_hints(@graph, @selected_id) != []} class="space-y-1">
              <p class="text-xs font-semibold opacity-70">
                Available variables — click to insert
              </p>
              <div class="flex flex-wrap gap-1" id="variable-picker" phx-hook=".VariablePicker">
                <code
                  :for={hint <- variable_hints(@graph, @selected_id)}
                  class="badge badge-ghost badge-sm font-mono cursor-pointer hover:badge-primary"
                  data-selector={hint}
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
                <span
                  :if={@run != nil and @run.status == :running}
                  class="flex items-center gap-1 text-xs opacity-80"
                >
                  <.icon name="hero-bolt-solid" class="size-4 flux-spinner" /> 88&nbsp;mph…
                </span>
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

            <div :if={@agent_activity != []} class="space-y-1">
              <p class="text-xs font-semibold opacity-70">Agent activity</p>
              <div class="rounded-box border border-base-200 p-2 space-y-1 max-h-48 overflow-y-auto">
                <div :for={entry <- @agent_activity} class="text-xs">
                  <%= case entry.kind do %>
                    <% :thought -> %>
                      <p :if={entry.text != ""} class="opacity-70 italic whitespace-pre-wrap">
                        <.icon name="hero-light-bulb" class="size-3 inline" />
                        {String.slice(entry.text, 0, 400)}
                      </p>
                    <% :tool_call -> %>
                      <p class="font-mono">
                        <.icon name="hero-wrench" class="size-3 inline text-info" />
                        {entry.name}({Jason.encode!(entry.arguments)})
                      </p>
                    <% :tool_result -> %>
                      <p class="font-mono opacity-70">
                        <.icon name="hero-arrow-uturn-left" class="size-3 inline text-success" />
                        {entry.content}
                      </p>
                  <% end %>
                </div>
              </div>
            </div>

            <div :if={@run_text != ""} class="space-y-1">
              <p class="text-xs font-semibold opacity-70">Output</p>
              <div class="rounded-box bg-base-200 p-3 text-sm whitespace-pre-wrap">{@run_text}</div>
            </div>

            <div
              :if={@run != nil and @run.status == :paused and @run.snapshot != nil}
              class="rounded-box border border-warning/40 bg-warning/5 p-3 space-y-2"
            >
              <p class="text-sm font-semibold">
                <.icon name="hero-hand-raised" class="size-4 inline" /> Waiting for input
              </p>
              <p class="text-sm">{@run.snapshot["prompt"]["prompt"]}</p>
              <div
                :if={List.wrap(@run.snapshot["prompt"]["options"]) != []}
                class="flex flex-wrap gap-1"
              >
                <span
                  :for={option <- @run.snapshot["prompt"]["options"]}
                  class="badge badge-ghost badge-sm"
                >
                  {option}
                </span>
              </div>
              <form
                :if={List.wrap(@run.snapshot["prompt"]["questions"]) != []}
                phx-submit="resume_run"
                class="space-y-2"
              >
                <FluxWeb.InterviewComponents.interview_fields
                  questions={@run.snapshot["prompt"]["questions"]}
                  errors={@resume_errors}
                />
                <button class="btn btn-primary btn-sm">Resume</button>
              </form>
              <form
                :if={List.wrap(@run.snapshot["prompt"]["questions"]) == []}
                phx-submit="resume_run"
                class="flex gap-2"
              >
                <input
                  type="text"
                  name="input"
                  placeholder="Your reply…"
                  class="input input-sm flex-1"
                />
                <button class="btn btn-primary btn-sm">Resume</button>
              </form>
            </div>

            <div :if={@run != nil and @run.status != :running} class="space-y-2">
              <div class="flex items-center gap-2">
                <span class={[
                  "badge badge-sm",
                  @run.status == :succeeded && "badge-success",
                  @run.status == :failed && "badge-error",
                  @run.status == :stopped && "badge-warning",
                  @run.status == :paused && "badge-info"
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
              <div
                :if={@can_export and run.status in [:succeeded, :failed]}
                class="px-3 pb-2"
              >
                <a
                  href={~p"/console/fluxes/#{@workflow.id}/runs/#{run.id}/fixture"}
                  class="link link-primary text-xs"
                  title="Download this run as a golden replay fixture"
                >
                  Download fixture
                </a>
              </div>

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
                    <div class="h-1.5 rounded bg-base-200 overflow-hidden mt-0.5">
                      <div
                        class={[
                          "h-full rounded",
                          (execution["status"] == "succeeded" && "bg-success/70") ||
                            (execution["status"] == "paused" && "bg-warning/70") ||
                            "bg-error/70"
                        ]}
                        style={"width: #{duration_percent(run.node_executions, execution)}%"}
                      >
                      </div>
                    </div>
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

      <dialog :if={@show_variables} class="modal modal-open">
        <div class="modal-box max-w-2xl space-y-4">
          <div class="flex items-center justify-between">
            <h3 class="font-bold">Variables</h3>
            <button class="btn btn-ghost btn-xs" phx-click="toggle_variables">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <form
            id="variables-form"
            phx-submit="save_variables"
            phx-change="variables_change"
            class="space-y-4"
          >
            <div class="space-y-2">
              <p class="text-sm font-semibold">
                Environment variables — reference as <code>{"{{env.KEY}}"}</code>
              </p>
              <div :for={{row, index} <- Enum.with_index(@env_rows)} class="flex gap-2">
                <input
                  type="text"
                  name={"envs[#{index}][key]"}
                  value={row["key"]}
                  placeholder="KEY"
                  class="input input-sm w-40 font-mono"
                />
                <input
                  type="text"
                  name={"envs[#{index}][value]"}
                  value={row["value"]}
                  placeholder="value"
                  class="input input-sm flex-1 font-mono"
                />
                <button
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="remove_env_row"
                  phx-value-index={index}
                >
                  ✕
                </button>
              </div>
              <button type="button" class="btn btn-outline btn-xs" phx-click="add_env_row">
                <.icon name="hero-plus" class="size-3" /> Add env variable
              </button>
            </div>

            <div class="space-y-2">
              <p class="text-sm font-semibold">
                Conversation variables — reference as <code>{"{{conversation.name}}"}</code>,
                written by Assigner nodes, persisted across chatflow turns
              </p>
              <div :for={{row, index} <- Enum.with_index(@conv_rows)} class="flex gap-2">
                <input
                  type="text"
                  name={"convs[#{index}][name]"}
                  value={row["name"]}
                  placeholder="name"
                  class="input input-sm w-40 font-mono"
                />
                <input
                  type="text"
                  name={"convs[#{index}][default]"}
                  value={row["default"]}
                  placeholder="default value"
                  class="input input-sm flex-1"
                />
                <button
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="remove_conv_row"
                  phx-value-index={index}
                >
                  ✕
                </button>
              </div>
              <button type="button" class="btn btn-outline btn-xs" phx-click="add_conv_row">
                <.icon name="hero-plus" class="size-3" /> Add conversation variable
              </button>
            </div>

            <button type="submit" class="btn btn-primary btn-sm">Save variables</button>
          </form>
        </div>
        <div class="modal-backdrop" phx-click="toggle_variables"></div>
      </dialog>

      <dialog :if={@show_versions} class="modal modal-open">
        <div class="modal-box space-y-4">
          <div class="flex items-center justify-between">
            <h3 class="font-bold">Published versions</h3>
            <button class="btn btn-ghost btn-xs" phx-click="toggle_versions">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <p :if={@versions == []} class="text-sm opacity-60">Nothing published yet.</p>
          <div
            :for={version <- @versions}
            class="flex items-center gap-3 rounded-box border border-base-200 px-3 py-2"
            id={"version-#{version.version}"}
          >
            <span class="badge badge-primary badge-sm">v{version.version}</span>
            <span class="text-xs opacity-60">
              {Calendar.strftime(version.inserted_at, "%Y-%m-%d %H:%M")}
            </span>
            <span class="text-xs opacity-60">
              {length(version.graph["nodes"] || [])} nodes
            </span>
            <button
              :if={@can_edit}
              class="btn btn-outline btn-xs ml-auto"
              phx-click="restore_version"
              phx-value-version={version.version}
              data-confirm={"Replace the draft with v#{version.version}? (Undo restores it.)"}
            >
              Restore to draft
            </button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="toggle_versions"></div>
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
            <form
              :if={@can_edit}
              phx-submit="save_site_theme"
              id="flux-site-theme-form"
              class="border-t border-base-200 pt-3 space-y-2"
            >
              <p class="text-xs font-semibold opacity-70">Appearance</p>
              <div class="flex items-end gap-2 flex-wrap">
                <label class="form-control">
                  <span class="label-text text-xs opacity-70 mb-1">Accent</span>
                  <input
                    type="color"
                    name="accent"
                    value={@workflow.site_theme["accent"] || "#570df8"}
                    class="h-8 w-14 cursor-pointer rounded border border-base-300"
                  />
                </label>
                <label class="form-control">
                  <span class="label-text text-xs opacity-70 mb-1">Title override</span>
                  <input
                    type="text"
                    name="title"
                    value={@workflow.site_theme["title"]}
                    placeholder={@workflow.name}
                    class="input input-bordered input-sm w-44"
                  />
                </label>
                <label class="form-control">
                  <span class="label-text text-xs opacity-70 mb-1">Logo URL (optional)</span>
                  <input
                    type="url"
                    name="logo_url"
                    value={@workflow.site_theme["logo_url"]}
                    placeholder="https://…/logo.png"
                    class="input input-bordered input-sm w-52"
                  />
                </label>
                <button class="btn btn-primary btn-sm">Save theme</button>
              </div>
            </form>
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
                trigger.type == :webhook && "badge-info",
                trigger.type == :schedule && "badge-accent",
                trigger.type == :plugin && "badge-secondary"
              ]}>
                {trigger.type}
              </span>
              <span :if={trigger.type == :schedule} class="text-xs opacity-70 font-mono">
                {(trigger.cron && trigger.cron) || "every #{trigger.interval_minutes} min"}
              </span>
              <span :if={trigger.type == :plugin} class="text-xs opacity-70 font-mono">
                {trigger.plugin_id} · polled every {trigger.interval_minutes} min
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
                  <option
                    :if={@trigger_plugins != []}
                    value="plugin"
                    selected={@trigger_type == "plugin"}
                  >
                    Plugin
                  </option>
                </select>
              </label>
              <label :if={@trigger_type == "webhook"} class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">
                  Shared secret (optional — callers must send it as x-flux-token)
                </span>
                <input
                  type="text"
                  name="webhook_secret"
                  placeholder="leave blank for token-only auth"
                  class="input input-bordered input-sm w-64 font-mono"
                />
              </label>
              <label :if={@trigger_type == "plugin"} class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">Trigger plugin</span>
                <select name="plugin_id" class="select select-bordered select-sm">
                  <option :for={plugin <- @trigger_plugins} value={plugin.id}>
                    {plugin.name}
                  </option>
                </select>
              </label>
              <label :if={@trigger_type in ["schedule", "plugin"]} class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">
                  {(@trigger_type == "plugin" && "Poll interval (minutes)") || "Interval (minutes)"}
                </span>
                <input
                  type="number"
                  name="interval_minutes"
                  min="1"
                  value={(@trigger_type == "plugin" && "5") || "60"}
                  class="input input-bordered input-sm w-32"
                />
              </label>
              <label :if={@trigger_type == "schedule"} class="form-control">
                <span class="label-text text-xs opacity-70 mb-1">
                  Cron (optional, UTC — overrides the interval)
                </span>
                <input
                  type="text"
                  name="cron"
                  placeholder="*/15 9-17 * * mon-fri"
                  class="input input-bordered input-sm w-52 font-mono"
                />
              </label>
            </div>
            <label class="form-control block">
              <span class="label-text text-xs opacity-70 mb-1">
                Static inputs (JSON object, optional — webhook payloads and plugin events override these)
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Minimap">
        export default {
          mounted() {
            const scroller = document.getElementById("canvas-scroll")
            const surface = document.getElementById("flux-canvas-surface")
            const viewport = this.el.querySelector("#minimap-viewport")
            const scale = () => (parseFloat(surface?.dataset.scale) || 100) / 100

            this.sync = () => {
              if (!scroller || !viewport) return
              const s = scale()
              viewport.setAttribute("x", scroller.scrollLeft / s)
              viewport.setAttribute("y", scroller.scrollTop / s)
              viewport.setAttribute("width", scroller.clientWidth / s)
              viewport.setAttribute("height", scroller.clientHeight / s)
            }

            scroller?.addEventListener("scroll", this.sync, {passive: true})
            window.addEventListener("resize", this.sync)

            this.el.addEventListener("click", (e) => {
              if (!scroller) return
              const rect = this.el.getBoundingClientRect()
              const s = scale()
              const cx = ((e.clientX - rect.left) / rect.width) * 3000
              const cy = ((e.clientY - rect.top) / rect.height) * 1600
              scroller.scrollTo({
                left: cx * s - scroller.clientWidth / 2,
                top: cy * s - scroller.clientHeight / 2,
                behavior: "smooth"
              })
            })

            this.sync()
          },
          updated() {
            this.sync && this.sync()
          },
          destroyed() {
            const scroller = document.getElementById("canvas-scroll")
            scroller?.removeEventListener("scroll", this.sync)
            window.removeEventListener("resize", this.sync)
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".VariablePicker">
        export default {
          mounted() {
            // Remember the last focused config input so a clicked hint can be
            // inserted at the cursor; fall back to copying the selector.
            this.onFocus = (e) => {
              const t = e.target
              if ((t.tagName === "INPUT" && t.type === "text") || t.tagName === "TEXTAREA") {
                this.lastInput = t
              }
            }
            document.addEventListener("focusin", this.onFocus)

            this.el.addEventListener("click", (e) => {
              const badge = e.target.closest("[data-selector]")
              if (!badge) return
              const text = "{{" + badge.dataset.selector + "}}"
              const input = this.lastInput
              if (input && document.body.contains(input)) {
                const start = input.selectionStart ?? input.value.length
                const end = input.selectionEnd ?? input.value.length
                input.value = input.value.slice(0, start) + text + input.value.slice(end)
                input.selectionStart = input.selectionEnd = start + text.length
                input.dispatchEvent(new Event("input", {bubbles: true}))
                input.focus()
              } else if (navigator.clipboard) {
                navigator.clipboard.writeText(text)
              }
            })
          },
          destroyed() {
            document.removeEventListener("focusin", this.onFocus)
          }
        }
      </script>

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
              // Docs links inside node cards are plain links, not drag handles.
              if (e.target.closest("[data-docs-link]")) return

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
              } else if (mod && key === "c") {
                this.pushEvent("copy_selection", {})
              } else if (mod && key === "v") {
                this.pushEvent("paste_clipboard", {})
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
