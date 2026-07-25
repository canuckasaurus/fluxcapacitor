defmodule FluxWeb.InvitationController do
  use FluxWeb, :controller

  alias Flux.Accounts

  @doc """
  Accepts a workspace invitation. Requires an authenticated account whose
  email matches the invitation; on success the new workspace becomes the
  account's current one.
  """
  def accept(conn, %{"token" => token}) do
    account = conn.assigns.current_scope.account

    case Accounts.accept_invitation(account, token) do
      {:ok, membership} ->
        {:ok, {workspace, _}} = Accounts.switch_workspace(account, membership.workspace_id)

        conn
        |> put_flash(:info, "Welcome to #{workspace.name}!")
        |> redirect(to: ~p"/console")

      {:error, :email_mismatch} ->
        conn
        |> put_flash(
          :error,
          "This invitation was sent to a different email address. " <>
            "Log in with the invited address to accept it."
        )
        |> redirect(to: ~p"/console")

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This invitation has expired. Ask for a new one.")
        |> redirect(to: ~p"/console")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "This invitation is no longer valid.")
        |> redirect(to: ~p"/console")
    end
  end
end
