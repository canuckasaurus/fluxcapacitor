defmodule FluxWeb.TriggerController do
  @moduledoc """
  Public webhook trigger: `POST /triggers/webhook/:token` starts the latest
  published version of the bound flux with the JSON payload as inputs
  (merged over the trigger's static inputs). Returns 202 with the run id.
  """
  use FluxWeb, :controller

  alias Flux.Workflows

  def webhook(conn, %{"token" => token} = params) do
    with {:ok, trigger} <- Workflows.fetch_trigger_by_token(token),
         {:ok, run} <- Workflows.run_from_trigger(trigger, extract_inputs(params)) do
      conn |> put_status(202) |> json(%{workflow_run_id: run.id, status: "running"})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{code: "not_found", message: "Unknown trigger"})

      {:error, :not_published} ->
        conn
        |> put_status(400)
        |> json(%{code: "workflow_not_published", message: "Publish this flux first"})

      {:error, {:invalid_graph, errors}} ->
        conn
        |> put_status(400)
        |> json(%{code: "invalid_graph", message: Enum.join(errors, "; ")})
    end
  end

  defp extract_inputs(params) do
    case params["inputs"] do
      inputs when is_map(inputs) -> inputs
      _absent -> Map.drop(params, ["token"])
    end
  end
end
