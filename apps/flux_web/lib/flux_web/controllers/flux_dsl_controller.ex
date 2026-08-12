defmodule FluxWeb.FluxDslController do
  @moduledoc "Downloads a flux as portable DSL."
  use FluxWeb, :controller

  alias Flux.Workflows
  alias Flux.Workflows.Workflow

  # The visitor transcript is public-site territory — the site token +
  # session visitor ref authorize it, not a console permission.
  plug FluxWeb.Plugs.RequirePermission,
       :app_import_export_dsl when action not in [:site_transcript]

  def export(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Workflows.get_workflow(scope, id) do
      %Workflow{} = workflow ->
        send_download(
          conn,
          {:binary, Flux.Workflows.DSL.export(workflow)},
          filename: "#{workflow.name}.yml",
          content_type: "application/yaml"
        )

      {:error, :not_found} ->
        conn |> put_flash(:error, "Flux not found.") |> redirect(to: ~p"/console/fluxes")
    end
  end

  @node_w 176
  @node_h 56

  @doc "The draft graph as a standalone SVG — for design docs and PRs."
  def export_svg(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Workflows.get_workflow(scope, id) do
      %Workflow{} = workflow ->
        send_download(
          conn,
          {:binary, graph_svg(workflow)},
          filename: "#{workflow.name}.svg",
          content_type: "image/svg+xml"
        )

      {:error, :not_found} ->
        conn |> put_flash(:error, "Flux not found.") |> redirect(to: ~p"/console/fluxes")
    end
  end

  defp graph_svg(workflow) do
    nodes = List.wrap(workflow.graph["nodes"])
    edges = List.wrap(workflow.graph["edges"])
    positions = Map.new(nodes, &{&1["id"], node_position(&1)})

    {max_x, max_y} =
      Enum.reduce(positions, {400, 300}, fn {_id, {x, y}}, {mx, my} ->
        {max(mx, x + @node_w + 40), max(my, y + @node_h + 40)}
      end)

    edge_lines =
      for edge <- edges,
          {x1, y1} = Map.get(positions, edge["source"], {0, 0}),
          {x2, y2} = Map.get(positions, edge["target"], {0, 0}) do
        ~s|<line x1="#{x1 + @node_w}" y1="#{y1 + div(@node_h, 2)}" x2="#{x2}" | <>
          ~s|y2="#{y2 + div(@node_h, 2)}" stroke="#888" stroke-width="1.5" | <>
          ~s|marker-end="url(#arrow)"/>|
      end

    node_boxes =
      for node <- nodes do
        {x, y} = positions[node["id"]]
        title = svg_escape(node["title"] || node["id"])
        type = svg_escape(node["type"] || "")

        ~s|<g transform="translate(#{x},#{y})">| <>
          ~s|<rect width="#{@node_w}" height="#{@node_h}" rx="8" fill="#f4f4f5" | <>
          ~s|stroke="#a1a1aa" stroke-width="1"/>| <>
          ~s|<text x="10" y="22" font-size="12" font-weight="bold" fill="#18181b">#{title}</text>| <>
          ~s|<text x="10" y="40" font-size="10" fill="#71717a">#{type}</text></g>|
      end

    ~s|<svg xmlns="http://www.w3.org/2000/svg" width="#{max_x}" height="#{max_y}" | <>
      ~s|viewBox="0 0 #{max_x} #{max_y}" font-family="system-ui, sans-serif">| <>
      ~s|<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" | <>
      ~s|markerHeight="7" orient="auto-start-reverse">| <>
      ~s|<path d="M 0 0 L 10 5 L 0 10 z" fill="#888"/></marker></defs>| <>
      Enum.join(edge_lines) <> Enum.join(node_boxes) <> "</svg>"
  end

  defp node_position(node) do
    x = get_in(node, ["position", "x"]) || 0
    y = get_in(node, ["position", "y"]) || 0
    {round(x * 1.0), round(y * 1.0)}
  end

  defp svg_escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.slice(0, 40)
  end

  @doc "Bulk export: the selected fluxes as one multi-document YAML file."
  def export_many(conn, %{"ids" => ids}) when is_list(ids) do
    scope = conn.assigns.current_scope

    documents =
      for id <- Enum.take(ids, 100),
          match?({:ok, _uuid}, Ecto.UUID.cast(id)),
          %Workflow{} = workflow <- [Workflows.get_workflow(scope, id)] do
        Flux.Workflows.DSL.export(workflow)
      end

    case documents do
      [] ->
        conn
        |> put_flash(:error, "Nothing to export.")
        |> redirect(to: ~p"/console/fluxes")

      documents ->
        send_download(
          conn,
          {:binary, Enum.join(documents, "\n---\n")},
          filename: "fluxes-export.yml",
          content_type: "application/yaml"
        )
    end
  end

  def export_many(conn, _params) do
    conn |> put_flash(:error, "Nothing to export.") |> redirect(to: ~p"/console/fluxes")
  end

  @doc "Downloads a finished run as a golden replay fixture."
  def run_fixture(conn, %{"run_id" => run_id}) do
    case Workflows.export_run_fixture(conn.assigns.current_scope, run_id) do
      {:ok, fixture} ->
        send_download(
          conn,
          {:binary, Jason.encode!(fixture, pretty: true)},
          filename: "run-fixture.json",
          content_type: "application/json"
        )

      {:error, :not_finished} ->
        conn
        |> put_flash(:error, "Only finished runs export as fixtures.")
        |> redirect(to: ~p"/console/fluxes")

      {:error, _reason} ->
        conn |> put_flash(:error, "Run not found.") |> redirect(to: ~p"/console/fluxes")
    end
  end

  @doc "Downloads a batch's rows, statuses, and outputs as CSV."
  def batch_results(conn, %{"id" => workflow_id, "batch_id" => batch_id}) do
    scope = conn.assigns.current_scope

    with %Flux.Workflows.WorkflowBatch{} = batch <- Workflows.get_batch(scope, batch_id),
         true <- batch.workflow_id == workflow_id || {:error, :not_found} do
      runs = Workflows.list_batch_runs(scope, batch_id)

      input_keys =
        runs
        |> Enum.flat_map(&Map.keys(&1.inputs))
        |> Enum.uniq()
        |> Enum.sort()

      header = input_keys ++ ["status", "error", "outputs", "total_tokens"]

      rows =
        for run <- runs do
          Enum.map(input_keys, &(run.inputs[&1] || "")) ++
            [
              to_string(run.status),
              run.error || "",
              Jason.encode!(run.outputs),
              (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0)
            ]
        end

      send_download(
        conn,
        {:binary, Flux.CSV.encode([header | rows])},
        filename: "batch-results.csv",
        content_type: "text/csv"
      )
    else
      _not_found ->
        conn
        |> put_flash(:error, "Batch not found.")
        |> redirect(to: ~p"/console/fluxes")
    end
  end

  @doc "Downloads an eval run's per-case results as CSV."
  def eval_results(conn, %{"id" => workflow_id, "eval_run_id" => eval_run_id}) do
    scope = conn.assigns.current_scope

    with %Flux.Evals.EvalRun{} = eval_run <- Flux.Evals.get_eval_run(scope, eval_run_id),
         true <- eval_run.workflow_id == workflow_id || {:error, :not_found} do
      keys =
        eval_run.results
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Enum.sort()

      rows = for result <- eval_run.results, do: Enum.map(keys, &csv_cell(result[&1]))

      send_download(
        conn,
        {:binary, Flux.CSV.encode([keys | rows])},
        filename: "eval-results.csv",
        content_type: "text/csv"
      )
    else
      _not_found ->
        conn
        |> put_flash(:error, "Eval run not found.")
        |> redirect(to: ~p"/console/fluxes")
    end
  end

  defp csv_cell(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp csv_cell(nil), do: ""
  defp csv_cell(value), do: Jason.encode!(value)

  @doc "Downloads a labeling project's labeled tasks as JSONL."
  def labeling_export(conn, %{"id" => project_id}) do
    case Flux.Labeling.export_jsonl(conn.assigns.current_scope, project_id) do
      {:ok, ""} ->
        conn
        |> put_flash(:error, "Nothing labeled yet.")
        |> redirect(to: ~p"/console/labeling")

      {:ok, jsonl} ->
        send_download(
          conn,
          {:binary, jsonl <> "\n"},
          filename: "labeled-tasks.jsonl",
          content_type: "application/jsonl"
        )

      _error ->
        conn |> put_flash(:error, "Project not found.") |> redirect(to: ~p"/console/labeling")
    end
  end

  @doc "Downloads an app's curated replies as fine-tune JSONL."
  def finetune_export(conn, %{"id" => id} = params) do
    filter = if params["filter"] == "all", do: :all, else: :liked

    case Flux.Chat.export_finetune(conn.assigns.current_scope, id, filter: filter) do
      {:ok, ""} ->
        conn
        |> put_flash(:error, "Nothing to export — like some replies or add annotations first.")
        |> redirect(to: ~p"/console/apps/#{id}/monitor")

      {:ok, jsonl} ->
        send_download(
          conn,
          {:binary, jsonl <> "\n"},
          filename: "finetune-#{filter}.jsonl",
          content_type: "application/jsonl"
        )

      _error ->
        conn |> put_flash(:error, "App not found.") |> redirect(to: ~p"/console/apps")
    end
  end

  @doc "One run as JSON: inputs, outputs, usage, and the per-node trace."
  def run_export(conn, %{"run_id" => run_id}) do
    scope = conn.assigns.current_scope

    case Flux.Workflows.get_run(scope, run_id) do
      %Flux.Workflows.WorkflowRun{} = run ->
        body =
          Jason.encode!(
            %{
              "id" => run.id,
              "workflow_id" => run.workflow_id,
              "status" => run.status,
              "source" => run.source,
              "version" => run.version,
              "inputs" => run.inputs,
              "outputs" => run.outputs,
              "error" => run.error,
              "usage" => run.usage,
              "elapsed_ms" => run.elapsed_ms,
              "started_at" => run.inserted_at,
              "node_executions" => run.node_executions
            },
            pretty: true
          )

        send_download(
          conn,
          {:binary, body},
          filename: "run-#{String.slice(run.id, 0, 8)}.json",
          content_type: "application/json"
        )

      _missing ->
        conn |> put_flash(:error, "Run not found.") |> redirect(to: ~p"/console/runs")
    end
  end

  @doc "Downloads a portable dataset archive (documents, cases, sources)."
  def dataset_export(conn, %{"id" => dataset_id}) do
    scope = conn.assigns.current_scope

    case Flux.RAG.export_dataset(scope, dataset_id) do
      {:ok, archive} ->
        send_download(
          conn,
          {:binary, Jason.encode!(archive, pretty: true)},
          filename: "#{archive["name"]}-dataset.json",
          content_type: "application/json"
        )

      _not_found ->
        conn |> put_flash(:error, "Dataset not found.") |> redirect(to: ~p"/console/knowledge")
    end
  end

  @doc "Monitoring tables as CSV: ?kind=feedback (rated replies) or usage (daily stats)."
  def monitor_export(conn, %{"id" => app_id} = params) do
    scope = conn.assigns.current_scope

    case Flux.Chat.get_app(scope, app_id) do
      %Flux.Chat.App{} = app ->
        {rows, name} =
          case params["kind"] do
            "annotations" ->
              rows =
                for annotation <- Flux.Chat.list_annotations(scope, app.id) do
                  [annotation.question, annotation.answer]
                end

              {[["question", "answer"] | rows], "annotations"}

            "usage" ->
              rows =
                for day <- Flux.Chat.usage_stats(scope, app.id, 90) do
                  [to_string(day.day), day.messages, day.input_tokens, day.output_tokens]
                end

              {[["day", "messages", "input_tokens", "output_tokens"] | rows], "usage"}

            _feedback ->
              rows =
                for %{message: message, question: question} <-
                      Flux.Chat.list_feedback(scope, app.id, :all, 1_000) do
                  [
                    Calendar.strftime(message.inserted_at, "%Y-%m-%d %H:%M:%S"),
                    to_string(message.feedback),
                    question || "",
                    message.content
                  ]
                end

              {[["when", "feedback", "question", "reply"] | rows], "feedback"}
          end

        send_download(
          conn,
          {:binary, Flux.CSV.encode(rows)},
          filename: "#{app.name}-#{name}.csv",
          content_type: "text/csv"
        )

      {:error, :not_found} ->
        conn |> put_flash(:error, "App not found.") |> redirect(to: ~p"/console/apps")
    end
  end

  @doc """
  A visitor downloads their own transcript (Markdown): the site token
  authorizes the app; the session visitor ref must own the conversation.
  """
  def site_transcript(conn, %{"token" => token, "conversation_id" => conversation_id}) do
    visitor_ref = get_session(conn, "site_visitor")

    with {:ok, app} <- Flux.Chat.get_app_by_site_token(token),
         scope = Flux.Chat.site_scope(app),
         %Flux.Chat.Conversation{} = conversation <-
           Flux.Chat.get_conversation(scope, conversation_id),
         true <-
           (conversation.app_id == app.id and is_binary(visitor_ref) and
              conversation.end_user_ref == visitor_ref) || :not_yours do
      messages = Flux.Chat.list_messages(scope, conversation.id)
      {body, content_type} = render_conversation(conversation, messages, "md")

      send_download(
        conn,
        {:binary, body},
        filename: "conversation-#{String.slice(conversation.id, 0, 8)}.md",
        content_type: content_type
      )
    else
      _denied -> send_resp(conn, 404, "not found")
    end
  end

  def conversation_export(conn, %{"id" => app_id, "conversation_id" => conversation_id} = params) do
    scope = conn.assigns.current_scope
    format = (params["format"] == "json" && "json") || "md"

    with %Flux.Chat.Conversation{app_id: ^app_id} = conversation <-
           Flux.Chat.get_conversation(scope, conversation_id),
         messages <- Flux.Chat.list_messages(scope, conversation.id) do
      {body, content_type} = render_conversation(conversation, messages, format)

      send_download(
        conn,
        {:binary, body},
        filename: "conversation-#{String.slice(conversation.id, 0, 8)}.#{format}",
        content_type: content_type
      )
    else
      _missing ->
        conn
        |> put_flash(:error, "Conversation not found.")
        |> redirect(to: ~p"/console/apps/#{app_id}")
    end
  end

  defp render_conversation(conversation, messages, "json") do
    body =
      Jason.encode!(
        %{
          "id" => conversation.id,
          "title" => conversation.title,
          "started_at" => conversation.inserted_at,
          "messages" =>
            Enum.map(messages, fn message ->
              %{
                "role" => message.role,
                "content" => message.content,
                "at" => message.inserted_at,
                "usage" => message.usage
              }
            end)
        },
        pretty: true
      )

    {body, "application/json"}
  end

  defp render_conversation(conversation, messages, "md") do
    header =
      "# #{conversation.title || "Conversation"}\n\n_Started #{conversation.inserted_at}_\n"

    turns =
      Enum.map_join(messages, "\n", fn message ->
        speaker = (message.role == :user && "**You**") || "**Assistant**"
        "\n#{speaker} — #{message.inserted_at}\n\n#{message.content}\n"
      end)

    {header <> turns, "text/markdown"}
  end

  def export_app(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Flux.Chat.get_app(scope, id) do
      %Flux.Chat.App{} = app ->
        send_download(
          conn,
          {:binary, Flux.Workflows.DSL.export_app(app)},
          filename: "#{app.name}.yml",
          content_type: "application/yaml"
        )

      {:error, :not_found} ->
        conn |> put_flash(:error, "App not found.") |> redirect(to: ~p"/console/apps")
    end
  end
end
