defmodule FluxWeb.V1.WorkflowRunController do
  @moduledoc """
  FluxCapacitor service API `POST /v1/workflows/run`: executes the latest published
  version of the token's workflow. Streaming SSE by default
  (`workflow_started` / `node_started` / `text_chunk` / `node_finished` /
  `workflow_finished`), or one JSON document with
  `response_mode: "blocking"`.
  """
  use FluxWeb, :controller

  alias Flux.Workflows

  @stream_timeout :timer.minutes(5)

  def create(conn, params) do
    case conn.assigns[:service_workflow] do
      nil ->
        error(conn, 403, "invalid_token_kind", "This endpoint requires a flux- workflow token")

      workflow ->
        run(conn, workflow, params)
    end
  end

  defp run(conn, workflow, params) do
    scope = conn.assigns.service_scope
    inputs = as_map(params["inputs"])

    case Workflows.latest_version(scope, workflow.id) do
      nil ->
        error(conn, 400, "workflow_not_published", "Publish this flux before calling the API")

      version ->
        case Workflows.start_run(scope, workflow, inputs,
               source: :api,
               graph: version.graph,
               version: version.version
             ) do
          {:ok, run} ->
            case Map.get(params, "response_mode", "streaming") do
              "blocking" -> respond_blocking(conn, run)
              _streaming -> respond_streaming(conn, run)
            end

          {:error, {:invalid_graph, errors}} ->
            error(conn, 400, "invalid_graph", Enum.join(errors, "; "))
        end
    end
  end

  defp as_map(inputs) when is_map(inputs), do: inputs
  defp as_map(_inputs), do: %{}

  ## Streaming

  defp respond_streaming(conn, run) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    {_status, conn} =
      sse(conn, %{
        event: "workflow_started",
        workflow_run_id: run.id,
        data: %{id: run.id, workflow_id: run.workflow_id, inputs: run.inputs}
      })

    stream_loop(conn, run)
  end

  defp stream_loop(conn, run) do
    receive do
      {:engine_event, event} ->
        case sse_engine_event(conn, run, event) do
          {:ok, conn} -> stream_loop(conn, run)
          {:error, _closed} -> conn
        end

      {:run_finished, finished} ->
        {_status, conn} =
          sse(conn, %{
            event: "workflow_finished",
            workflow_run_id: run.id,
            data: %{
              id: finished.id,
              status: finished.status,
              outputs: finished.outputs,
              error: finished.error,
              elapsed_time: ms_to_seconds(finished.elapsed_ms)
            }
          })

        conn
    after
      @stream_timeout ->
        {_status, conn} =
          sse(conn, %{event: "error", code: "timeout", message: "Stream timed out"})

        conn
    end
  end

  defp sse_engine_event(conn, run, {:node_started, data}) do
    sse(conn, %{
      event: "node_started",
      workflow_run_id: run.id,
      data: %{node_id: data.node_id, node_type: data.node_type, title: data.title}
    })
  end

  defp sse_engine_event(conn, run, {:node_chunk, data}) do
    sse(conn, %{
      event: "text_chunk",
      workflow_run_id: run.id,
      data: %{text: data.delta, from_node_id: data.node_id}
    })
  end

  defp sse_engine_event(conn, run, {:node_finished, data}) do
    sse(conn, %{
      event: "node_finished",
      workflow_run_id: run.id,
      data: %{
        node_id: data.node_id,
        status: "succeeded",
        outputs: data.outputs,
        elapsed_time: ms_to_seconds(data.elapsed_ms)
      }
    })
  end

  defp sse_engine_event(conn, run, {:node_failed, data}) do
    sse(conn, %{
      event: "node_finished",
      workflow_run_id: run.id,
      data: %{node_id: data.node_id, status: "failed", error: data.error}
    })
  end

  defp sse_engine_event(conn, _run, _other), do: {:ok, conn}

  defp sse(conn, payload), do: chunk(conn, "data: " <> Jason.encode!(payload) <> "\n\n")

  ## Blocking

  defp respond_blocking(conn, run) do
    receive do
      {:engine_event, _event} ->
        respond_blocking(conn, run)

      {:run_finished, finished} ->
        json(conn, %{
          workflow_run_id: finished.id,
          data: %{
            id: finished.id,
            workflow_id: finished.workflow_id,
            status: finished.status,
            outputs: finished.outputs,
            error: finished.error,
            elapsed_time: ms_to_seconds(finished.elapsed_ms),
            created_at: DateTime.to_unix(finished.inserted_at)
          }
        })
    after
      @stream_timeout ->
        error(conn, 504, "timeout", "Run timed out")
    end
  end

  defp ms_to_seconds(nil), do: nil
  defp ms_to_seconds(ms), do: ms / 1000

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{code: code, message: message, status: status})
  end
end
