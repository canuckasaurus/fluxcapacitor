defmodule FluxWeb.FluxDslController do
  @moduledoc "Downloads a flux as portable DSL."
  use FluxWeb, :controller

  alias Flux.Workflows
  alias Flux.Workflows.Workflow

  plug FluxWeb.Plugs.RequirePermission, :app_import_export_dsl

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
