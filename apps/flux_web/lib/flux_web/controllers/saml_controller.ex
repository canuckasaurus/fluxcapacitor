defmodule FluxWeb.SamlController do
  @moduledoc """
  Lands a SAML sign-on: Samly consumed the assertion at
  `/sso/sp/consume/idp` and redirected here (`target_url`); the email in
  the assertion provisions or resolves an account exactly like OIDC.
  """
  use FluxWeb, :controller

  alias Flux.Accounts
  alias FluxWeb.AccountAuth

  def complete(conn, _params) do
    with %Samly.Assertion{} = assertion <- Samly.get_active_assertion(conn),
         {:ok, email} <- FluxWeb.SAML.assertion_email(assertion),
         {:ok, account} <- Accounts.get_or_register_sso_account(email) do
      # Workspaces with an SSO role mapping get roles synced from the
      # assertion's attributes — same config the OIDC flow reads.
      Accounts.apply_oidc_roles(account, assertion.attributes || %{})
      AccountAuth.log_in_account(conn, account)
    else
      nil ->
        fail(conn, "No SAML session found — start again from the login page.")

      {:error, :no_email} ->
        fail(conn, "The identity provider sent no email address.")

      {:error, _changeset} ->
        fail(conn, "Could not provision an account for that email.")
    end
  end

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/accounts/log-in")
  end
end
