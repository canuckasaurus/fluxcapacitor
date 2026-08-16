defmodule FluxWeb.Plugs.ServiceAuth do
  @moduledoc """
  Authenticates service-API requests by bearer token: `app-…` resolves to a
  chat app (interoperable), `flux-…` to a workflow. Assigns
  `:service_app` / `:service_workflow` (one of them nil) and a
  workspace-bearing `:service_scope`.
  """
  import Plug.Conn

  alias Flux.Accounts.Scope
  alias Flux.Chat
  alias Flux.Workflows

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, assigns} <- resolve(raw),
         :ok <- check_dataset_scope(conn, assigns),
         :ok <- check_ip(conn, assigns[:workspace_id]) do
      workspace_id = assigns[:workspace_id]

      # Token possession grants editor-level authority in the workspace,
      # so RBAC-checked context functions (datasets, documents) work for
      # service callers without per-account membership.
      scope = %Scope{
        account: nil,
        workspace: %Flux.Accounts.Workspace{id: workspace_id},
        membership: %Flux.Accounts.Membership{workspace_id: workspace_id, role: :editor}
      }

      conn
      |> assign(:service_app, assigns[:app])
      |> assign(:service_workflow, assigns[:workflow])
      |> assign(:service_token, assigns[:token])
      |> assign(:service_dataset_id, assigns[:dataset_id])
      |> assign(:service_scope, scope)
    else
      {:error, :dataset_scope} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{
            code: "invalid_token_kind",
            message: "A ds- token only opens its own dataset's endpoints"
          })
        )
        |> halt()

      {:error, :token_expired} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{code: "token_expired", message: "This API token has expired"})
        )
        |> halt()

      {:error, :ip_forbidden} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{
            code: "ip_forbidden",
            message: "This workspace restricts API access by IP address"
          })
        )
        |> halt()

      _unauthorized ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{code: "unauthorized", message: "Invalid API token"}))
        |> halt()
    end
  end

  # A ds- token is confined to its dataset's paths: /v1/datasets/<id>/…
  # only. Everything else — other datasets, dataset creation, the whole
  # rest of the API — answers 403.
  defp check_dataset_scope(conn, %{dataset_id: dataset_id}) when is_binary(dataset_id) do
    if String.starts_with?(conn.request_path, "/v1/datasets/#{dataset_id}/") do
      :ok
    else
      {:error, :dataset_scope}
    end
  end

  defp check_dataset_scope(_conn, _assigns), do: :ok

  # Workspace IP allowlist: a valid token from the wrong network is
  # still refused, and the attempt lands in the audit trail.
  defp check_ip(conn, workspace_id) do
    if Flux.IPAllowlist.allowed?(workspace_id, conn.remote_ip) do
      :ok
    else
      scope = %Scope{
        account: nil,
        workspace: %Flux.Accounts.Workspace{id: workspace_id},
        membership: %Flux.Accounts.Membership{workspace_id: workspace_id, role: :editor}
      }

      Flux.Audit.record(scope, "api.ip_rejected",
        metadata: %{"ip" => to_string(:inet.ntoa(conn.remote_ip)), "path" => conn.request_path}
      )

      {:error, :ip_forbidden}
    end
  end

  # Dataset keys open exactly one dataset's knowledge endpoints and
  # nothing else — the path check is the whole privilege boundary.
  defp resolve("ds-" <> _rest = raw) do
    with {:ok, dataset_id, workspace_id, token} <- Chat.fetch_dataset_by_token(raw) do
      {:ok,
       %{
         app: nil,
         workflow: nil,
         token: token,
         workspace_id: workspace_id,
         dataset_id: dataset_id
       }}
    end
  end

  defp resolve("app-" <> _rest = raw) do
    with {:ok, app, token} <- Chat.fetch_app_by_token(raw) do
      {:ok, %{app: app, workflow: nil, token: token, workspace_id: app.workspace_id}}
    end
  end

  defp resolve("flux-" <> _rest = raw) do
    with {:ok, workflow, token} <- Workflows.fetch_workflow_by_token(raw) do
      {:ok, %{app: nil, workflow: workflow, token: token, workspace_id: workflow.workspace_id}}
    end
  end

  # Workspace tokens drive datasets/quality/models endpoints; app- and
  # flux-specific routes still answer 403 invalid_token_kind for them.
  defp resolve("ws-" <> _rest = raw) do
    with {:ok, workspace_id, token} <- Chat.fetch_workspace_by_token(raw) do
      {:ok, %{app: nil, workflow: nil, token: token, workspace_id: workspace_id}}
    end
  end

  defp resolve(_other), do: {:error, :invalid_token}
end
