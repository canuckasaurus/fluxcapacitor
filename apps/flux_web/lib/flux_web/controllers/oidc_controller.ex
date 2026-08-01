defmodule FluxWeb.OIDCController do
  @moduledoc "Browser endpoints for the OIDC login flow (see FluxWeb.OIDC)."
  use FluxWeb, :controller

  alias Flux.Accounts
  alias FluxWeb.AccountAuth
  alias FluxWeb.OIDC

  def request(conn, _params) do
    with true <- OIDC.configured?() || {:error, "Single sign-on is not configured."},
         state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
         {:ok, destination} <- OIDC.authorize_url(url(~p"/auth/oidc/callback"), state) do
      conn
      |> put_session(:oidc_state, state)
      |> redirect(external: destination)
    else
      {:error, message} -> fail(conn, message)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :oidc_state)
    conn = delete_session(conn, :oidc_state)

    with true <-
           (is_binary(expected) and Plug.Crypto.secure_compare(state, expected)) ||
             {:error, "login session mismatch — try again"},
         {:ok, email} <- OIDC.exchange_code(code, url(~p"/auth/oidc/callback")),
         {:ok, account} <- Accounts.get_or_register_sso_account(email) do
      AccountAuth.log_in_account(conn, account)
    else
      {:error, message} when is_binary(message) -> fail(conn, message)
      {:error, _changeset} -> fail(conn, "could not provision an account for that email")
    end
  end

  # The provider refused (or sent no code) — surface its error code.
  def callback(conn, params) do
    fail(conn, "Sign-on failed: #{params["error"] || "no authorization code returned"}")
  end

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/accounts/log-in")
  end
end
