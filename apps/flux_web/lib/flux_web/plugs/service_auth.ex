defmodule FluxWeb.Plugs.ServiceAuth do
  @moduledoc """
  Authenticates service-API requests by `Authorization: Bearer app-…` token
  (Dify-compatible). Assigns `:service_app` and a workspace-bearing scope
  built from the app's workspace.
  """
  import Plug.Conn

  alias Flux.Accounts.Scope
  alias Flux.Chat

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, app, _token} <- Chat.fetch_app_by_token(raw) do
      scope = %Scope{
        account: nil,
        workspace: %Flux.Accounts.Workspace{id: app.workspace_id},
        membership: nil
      }

      conn
      |> assign(:service_app, app)
      |> assign(:service_scope, scope)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{code: "unauthorized", message: "Invalid API token"}))
        |> halt()
    end
  end
end
