defmodule FluxWeb.Hardening2WebTest do
  @moduledoc "Web-layer regression coverage for the batch-71 hardening exercise."
  use FluxWeb.ConnCase, async: true

  import Flux.AccountsFixtures

  alias Flux.Accounts

  defp enroll_totp(account) do
    {account, _uri} = Accounts.init_totp(account)
    code = NimbleTOTP.verification_code(account.totp_secret)
    {:ok, account, _recovery} = Accounts.confirm_totp(account, code)
    account
  end

  describe "2FA can't be skipped via the magic-link front door" do
    test "a TOTP-enrolled account is challenged, not logged in", %{conn: conn} do
      account = enroll_totp(account_fixture())
      {token, _hashed} = generate_account_magic_link_token(account)

      conn = post(conn, ~p"/accounts/log-in", %{"account" => %{"token" => token}})

      # Parked at the TOTP challenge — no session token minted yet.
      assert redirected_to(conn) == ~p"/accounts/totp"
      refute get_session(conn, :account_token)
      assert get_session(conn, :totp_pending)["account_id"] == account.id
    end

    test "an account without TOTP still logs straight in", %{conn: conn} do
      account = account_fixture()
      {token, _hashed} = generate_account_magic_link_token(account)

      conn = post(conn, ~p"/accounts/log-in", %{"account" => %{"token" => token}})

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/console"
    end
  end
end
