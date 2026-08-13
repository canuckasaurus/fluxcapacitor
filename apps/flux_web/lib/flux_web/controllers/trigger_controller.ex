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
         :ok <- verify_secret(conn, trigger),
         {:ok, run} <- Workflows.run_from_trigger(trigger, extract_inputs(params)) do
      conn |> put_status(202) |> json(%{workflow_run_id: run.id, status: "running"})
    else
      {:error, :bad_secret} ->
        conn
        |> put_status(401)
        |> json(%{code: "invalid_secret", message: "x-flux-token does not match"})

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

  @doc """
  Inbound-mail trigger: `POST /triggers/email/:token` with a
  Mailgun/SES-style form or JSON body. `from`/`sender`, `subject`, and
  `body-plain`/`text`/`stripped-text` map to run inputs (the body doubles
  as `query` so knowledge-flux starts work unmodified).
  """
  def email(conn, %{"token" => "emt_" <> _rest = token} = params) do
    with {:ok, %{type: :email} = trigger} <- Workflows.fetch_trigger_by_token(token),
         :ok <- verify_secret(conn, trigger),
         {:ok, run} <- Workflows.run_from_trigger(trigger, email_inputs(params)) do
      conn |> put_status(202) |> json(%{workflow_run_id: run.id, status: "running"})
    else
      {:ok, %{type: _not_email}} ->
        conn |> put_status(404) |> json(%{code: "not_found", message: "Unknown trigger"})

      {:error, :bad_secret} ->
        conn
        |> put_status(401)
        |> json(%{code: "invalid_secret", message: "x-flux-token does not match"})

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

  def email(conn, _params) do
    conn |> put_status(404) |> json(%{code: "not_found", message: "Unknown trigger"})
  end

  defp email_inputs(params) do
    body =
      params["body-plain"] || params["stripped-text"] || params["text"] ||
        params["body"] || ""

    %{
      "from" => params["from"] || params["sender"] || "",
      "subject" => params["subject"] || "",
      "body" => body,
      "query" => body
    }
  end

  # A configured trigger secret must arrive as x-flux-token (constant-time
  # compared); triggers without one keep the token-in-URL contract.
  defp verify_secret(conn, trigger) do
    case trigger.webhook_secret do
      empty when empty in [nil, ""] ->
        :ok

      secret ->
        case get_req_header(conn, "x-flux-token") do
          [provided] ->
            if Plug.Crypto.secure_compare(provided, secret), do: :ok, else: {:error, :bad_secret}

          _missing ->
            {:error, :bad_secret}
        end
    end
  end

  defp extract_inputs(params) do
    case params["inputs"] do
      inputs when is_map(inputs) -> inputs
      _absent -> Map.drop(params, ["token"])
    end
  end
end
