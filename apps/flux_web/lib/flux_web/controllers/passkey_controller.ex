defmodule FluxWeb.PasskeyController do
  @moduledoc """
  Passkey (WebAuthn) sign-in. The challenge endpoint parks a Wax
  challenge in the session; the login endpoint verifies the browser's
  assertion against it and signs the account in. Registration lives in
  the account-settings LiveView (same process holds the challenge);
  only login needs controllers because only controllers can write the
  session cookie.
  """
  use FluxWeb, :controller

  alias Flux.Accounts
  alias FluxWeb.AccountAuth

  @doc "Mints an authentication challenge (username-less: any resident key)."
  def login_challenge(conn, _params) do
    challenge =
      Wax.new_authentication_challenge(
        origin: FluxWeb.Endpoint.url(),
        rp_id: :auto,
        allow_credentials: [],
        user_verification: "preferred"
      )

    conn
    |> put_session(:passkey_challenge, :erlang.term_to_binary(challenge))
    |> json(%{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp_id: challenge.rp_id
    })
  end

  @doc "Verifies the assertion (form POST, so the redirect just works)."
  def login(conn, params) do
    with challenge_bin when is_binary(challenge_bin) <-
           get_session(conn, :passkey_challenge) || :no_challenge,
         challenge = Plug.Crypto.non_executable_binary_to_term(challenge_bin, [:safe]),
         {:ok, raw_id} <- decode(params["raw_id"]),
         {:ok, auth_data_bin} <- decode(params["authenticator_data"]),
         {:ok, signature} <- decode(params["signature"]),
         {:ok, client_data_json} <- decode(params["client_data_json"]),
         credential_id = Base.url_encode64(raw_id, padding: false),
         {:ok, account, passkey, cose_key} <- Accounts.find_passkey(credential_id),
         {:ok, auth_data} <-
           Wax.authenticate(
             credential_id,
             auth_data_bin,
             signature,
             client_data_json,
             challenge,
             [{credential_id, cose_key}]
           ) do
      Accounts.bump_passkey_sign_count(passkey, auth_data.sign_count)

      conn
      |> delete_session(:passkey_challenge)
      |> put_flash(:info, "Welcome back!")
      |> AccountAuth.log_in_account(account)
    else
      _invalid ->
        conn
        |> put_flash(:error, "Passkey sign-in didn't work — try again or use another method.")
        |> redirect(to: ~p"/accounts/log-in")
    end
  end

  defp decode(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode(_missing), do: :error
end
