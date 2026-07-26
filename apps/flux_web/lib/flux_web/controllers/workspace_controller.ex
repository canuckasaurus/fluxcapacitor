defmodule FluxWeb.WorkspaceController do
  use FluxWeb, :controller

  alias Flux.Accounts

  def switch(conn, %{"id" => workspace_id}) do
    case Accounts.switch_workspace(conn.assigns.current_scope.account, workspace_id) do
      {:ok, {workspace, _membership}} ->
        conn
        |> put_flash(:info, "Switched to #{workspace.name}.")
        |> redirect(to: ~p"/console")

      {:error, :not_a_member} ->
        conn
        |> put_flash(:error, "You're not a member of that workspace.")
        |> redirect(to: ~p"/console")
    end
  end
end
