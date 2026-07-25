defmodule FluxWeb.AccountSessionController do
  use FluxWeb, :controller

  alias Flux.Accounts
  alias FluxWeb.AccountAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "Account confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"account" => %{"token" => token} = account_params}, info) do
    case Accounts.login_account_by_magic_link(token) do
      {:ok, {account, tokens_to_disconnect}} ->
        AccountAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> AccountAuth.log_in_account(account, account_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/accounts/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"account" => account_params}, info) do
    %{"email" => email, "password" => password} = account_params

    if account = Accounts.get_account_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> AccountAuth.log_in_account(account, account_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/accounts/log-in")
    end
  end

  def update_password(conn, %{"account" => account_params} = params) do
    account = conn.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)
    {:ok, {_account, expired_tokens}} = Accounts.update_account_password(account, account_params)

    # disconnect all existing LiveViews with old sessions
    AccountAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:account_return_to, ~p"/accounts/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> AccountAuth.log_out_account()
  end
end
