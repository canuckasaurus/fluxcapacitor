defmodule Flux.Webhooks do
  @moduledoc """
  Outgoing webhooks: workspace-registered HTTPS endpoints that receive
  signed run-lifecycle events (`run.succeeded`, `run.failed`, `run.paused`,
  `run.stopped`).

  Delivery rides `Flux.Workflows.AlertWorker` — Oban-retried, SSRF-guarded
  at send time, and HMAC-SHA256 signed (`x-flux-signature: sha256=<hex>`
  over the exact body bytes) with the endpoint's secret. Payloads are thin:
  IDs, status, and totals — receivers fetch anything else via `/v1`.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.RBAC
  alias Flux.Repo
  alias Flux.Webhooks.Endpoint

  @run_events ~w(run.succeeded run.failed run.paused run.stopped)

  def run_events, do: @run_events

  def list_endpoints(%Scope{} = scope) do
    Endpoint
    |> Repo.scoped(scope)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  def create_endpoint(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :api_extension_manage) do
      secret = "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      %Endpoint{workspace_id: Scope.workspace_id(scope), secret: secret}
      |> Endpoint.changeset(attrs)
      |> Repo.insert()
      |> tap_audit(scope, "webhook.create")
    end
  end

  def update_endpoint(%Scope{} = scope, endpoint_id, attrs) do
    with :ok <- RBAC.authorize(scope, :api_extension_manage),
         %Endpoint{} = endpoint <- get_endpoint(scope, endpoint_id) do
      endpoint
      |> Endpoint.changeset(attrs)
      |> Repo.update()
      |> tap_audit(scope, "webhook.update")
    end
  end

  def delete_endpoint(%Scope{} = scope, endpoint_id) do
    with :ok <- RBAC.authorize(scope, :api_extension_manage),
         %Endpoint{} = endpoint <- get_endpoint(scope, endpoint_id),
         {:ok, deleted} <- Repo.delete(endpoint) do
      Flux.Audit.record(scope, "webhook.delete",
        resource_type: "webhook",
        resource_id: deleted.id
      )

      {:ok, deleted}
    end
  end

  @doc """
  Fans a finished run out to every enabled endpoint subscribed to its
  event. Called from the run lifecycle (no scope — runs finish in
  supervised tasks), so endpoints are loaded by workspace directly.
  """
  def dispatch_run_event(run) do
    event = "run.#{run.status}"

    endpoints =
      Repo.all(
        from e in Endpoint,
          where: e.workspace_id == type(^run.workspace_id, :binary_id) and e.enabled == true
      )

    payload = run_payload(event, run)

    for endpoint <- endpoints, event in endpoint.events or "*" in endpoint.events do
      %{"url" => endpoint.url, "secret" => endpoint.secret, "payload" => payload}
      |> Flux.Workflows.AlertWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  defp run_payload(event, run) do
    %{
      "event" => event,
      "run_id" => run.id,
      "workflow_id" => run.workflow_id,
      "status" => to_string(run.status),
      "error" => run.error,
      "elapsed_ms" => run.elapsed_ms,
      "total_tokens" => (run.usage["input_tokens"] || 0) + (run.usage["output_tokens"] || 0),
      "occurred_at" => DateTime.to_iso8601(run.updated_at)
    }
  end

  defp get_endpoint(scope, endpoint_id) do
    Repo.one(Repo.scoped(where(Endpoint, id: ^endpoint_id), scope)) || {:error, :not_found}
  end

  defp tap_audit({:ok, endpoint} = result, scope, action) do
    Flux.Audit.record(scope, action,
      resource_type: "webhook",
      resource_id: endpoint.id,
      metadata: %{"url" => endpoint.url}
    )

    result
  end

  defp tap_audit(other, _scope, _action), do: other
end
