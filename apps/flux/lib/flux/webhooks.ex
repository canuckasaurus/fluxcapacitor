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
  @other_events ~w(batch.completed eval.completed feedback.created
                   labeling.task_labeled labeling.project_completed
                   document.indexed document.failed dataset.synced
                   audit.recorded conversation.started message.completed
                   handoff.requested)

  def run_events, do: @run_events

  @doc "Every subscribable event (incl. routed notification kinds)."
  def events, do: @run_events ++ @other_events ++ Flux.Notifications.webhook_events()

  @doc """
  Sends a signed `webhook.test` event to one endpoint synchronously and
  returns what happened — the "does my receiver work?" button.
  """
  def send_test(%Scope{} = scope, endpoint_id) do
    with :ok <- RBAC.authorize(scope, :api_extension_manage),
         %Endpoint{} = endpoint <-
           Repo.one(Repo.scoped(where(Endpoint, id: ^endpoint_id), scope)) ||
             {:error, :not_found},
         :ok <- Flux.SSRF.verify_url(endpoint.url) do
      body =
        Jason.encode!(%{
          event: "webhook.test",
          message: "FluxCapacitor test event — your receiver works.",
          sent_at: DateTime.utc_now(:second)
        })

      signature =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, endpoint.secret, body) |> Base.encode16(case: :lower))

      case Req.post(
             [
               url: endpoint.url,
               body: body,
               headers: [
                 {"content-type", "application/json"},
                 {"x-flux-signature", signature}
               ],
               retry: false,
               receive_timeout: 10_000
             ] ++ Application.get_env(:flux, :alert_req_options, [])
           ) do
        {:ok, %{status: status}} -> {:ok, status}
        {:error, exception} -> {:error, Exception.message(exception)}
      end
    end
  end

  @doc """
  Regenerates an endpoint's signing secret. Receivers must switch to the
  new `whsec_` immediately — show it once, like key minting.
  """
  def rotate_secret(%Flux.Accounts.Scope{} = scope, endpoint_id) do
    with :ok <- Flux.RBAC.authorize(scope, :api_extension_manage),
         %Endpoint{} = endpoint <-
           Repo.one(Repo.scoped(where(Endpoint, id: ^endpoint_id), scope)) ||
             {:error, :not_found} do
      secret = "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      with {:ok, updated} <-
             endpoint |> Ecto.Changeset.change(secret: secret) |> Repo.update() do
        Flux.Audit.record(scope, "webhook.rotate_secret",
          resource_type: "webhook_endpoint",
          resource_id: endpoint.id,
          metadata: %{"url" => endpoint.url}
        )

        {:ok, updated}
      end
    end
  end

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
    dispatch(run.workspace_id, "run.#{run.status}", run_payload("run.#{run.status}", run))
  end

  defmodule Delivery do
    @moduledoc "One webhook delivery: its outcome across Oban attempts."
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "webhook_deliveries" do
      belongs_to :workspace, Flux.Accounts.Workspace
      belongs_to :endpoint, Flux.Webhooks.Endpoint

      field :event, :string
      field :url, :string
      field :status, :integer
      field :attempts, :integer, default: 0
      field :last_error, :string
      field :payload, :map, default: %{}

      timestamps(type: :utc_datetime)
    end
  end

  @doc "Thin fan-out for any event; the payload gets the event name merged in."
  def dispatch(workspace_id, event, payload) do
    endpoints =
      Repo.all(
        from e in Endpoint,
          where: e.workspace_id == type(^workspace_id, :binary_id) and e.enabled == true
      )

    payload = Map.put(payload, "event", event)

    for endpoint <- endpoints, event in endpoint.events or "*" in endpoint.events do
      delivery =
        Repo.insert!(%Delivery{
          workspace_id: endpoint.workspace_id,
          endpoint_id: endpoint.id,
          event: event,
          url: endpoint.url,
          payload: payload
        })

      %{
        "url" => endpoint.url,
        "secret" => endpoint.secret,
        "payload" => payload,
        "format" => endpoint.format,
        "delivery_id" => delivery.id
      }
      |> Flux.Workflows.AlertWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  @doc "Recent deliveries, newest first — the delivery log in settings."
  def list_deliveries(%Scope{} = scope, limit \\ 50) do
    Delivery
    |> Repo.scoped(scope)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Re-enqueues a delivery (fresh attempt counter on the same payload)."
  def retry_delivery(%Scope{} = scope, delivery_id) do
    with :ok <- RBAC.authorize(scope, :api_extension_manage),
         %Delivery{} = delivery <-
           Repo.one(Repo.scoped(where(Delivery, id: ^delivery_id), scope)) ||
             {:error, :not_found},
         %Endpoint{} = endpoint <-
           Repo.one(Repo.scoped(where(Endpoint, id: ^delivery.endpoint_id), scope)) ||
             {:error, :endpoint_gone} do
      {:ok, _job} =
        %{
          "url" => endpoint.url,
          "secret" => endpoint.secret,
          "payload" => delivery.payload,
          "format" => endpoint.format,
          "delivery_id" => delivery.id
        }
        |> Flux.Workflows.AlertWorker.new()
        |> Oban.insert()

      {:ok, delivery}
    end
  end

  @doc false
  # Called from the delivery worker after each attempt.
  def record_attempt(nil, _attempt, _status, _error), do: :ok

  def record_attempt(delivery_id, attempt, status, error) do
    case Repo.get(Delivery, delivery_id, skip_workspace_guard: true) do
      nil ->
        :ok

      delivery ->
        delivery
        |> Ecto.Changeset.change(
          attempts: max(delivery.attempts, attempt),
          status: status,
          last_error: error && String.slice(error, 0, 255)
        )
        |> Repo.update()

        :ok
    end
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
