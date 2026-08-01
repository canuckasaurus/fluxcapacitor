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
         {:ok, assigns} <- resolve(raw) do
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
      |> assign(:service_scope, scope)
    else
      _unauthorized ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{code: "unauthorized", message: "Invalid API token"}))
        |> halt()
    end
  end

  defp resolve("app-" <> _rest = raw) do
    with {:ok, app, _token} <- Chat.fetch_app_by_token(raw) do
      {:ok, %{app: app, workflow: nil, workspace_id: app.workspace_id}}
    end
  end

  defp resolve("flux-" <> _rest = raw) do
    with {:ok, workflow, _token} <- Workflows.fetch_workflow_by_token(raw) do
      {:ok, %{app: nil, workflow: workflow, workspace_id: workflow.workspace_id}}
    end
  end

  defp resolve(_other), do: {:error, :invalid_token}
end
