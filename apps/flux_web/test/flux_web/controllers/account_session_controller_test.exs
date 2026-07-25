defmodule FluxWeb.AccountSessionControllerTest do
  use FluxWeb.ConnCase, async: true

  import Flux.AccountsFixtures
  alias Flux.Accounts

  setup do
    %{unconfirmed_account: unconfirmed_account_fixture(), account: account_fixture()}
  end

  describe "POST /accounts/log-in - email and password" do
    test "logs the account in", %{conn: conn, account: account} do
      account = set_password(account)

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"email" => account.email, "password" => valid_account_password()}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/console"

      # Now do a logged in request and assert on the console chrome
      {:ok, _} = Accounts.create_workspace(account, %{name: "Test Workspace"})
      conn = get(conn, ~p"/console")
      response = html_response(conn, 200)
      assert response =~ account.email
      assert response =~ ~p"/accounts/settings"
      assert response =~ ~p"/accounts/log-out"
    end

    test "logs the account in with remember me", %{conn: conn, account: account} do
      account = set_password(account)

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_flux_web_account_remember_me"]
      assert redirected_to(conn) == ~p"/console"
    end

    test "logs the account in with return to", %{conn: conn, account: account} do
      account = set_password(account)

      conn =
        conn
        |> init_test_session(account_return_to: "/foo/bar")
        |> post(~p"/accounts/log-in", %{
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/accounts/log-in?mode=password", %{
          "account" => %{"email" => account.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/accounts/log-in"
    end
  end

  describe "POST /accounts/log-in - magic link" do
    test "logs the account in", %{conn: conn, account: account} do
      {token, _hashed_token} = generate_account_magic_link_token(account)

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"token" => token}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/console"

      # Now do a logged in request and assert on the console chrome
      {:ok, _} = Accounts.create_workspace(account, %{name: "Test Workspace"})
      conn = get(conn, ~p"/console")
      response = html_response(conn, 200)
      assert response =~ account.email
      assert response =~ ~p"/accounts/settings"
      assert response =~ ~p"/accounts/log-out"
    end

    test "confirms unconfirmed account", %{conn: conn, unconfirmed_account: account} do
      {token, _hashed_token} = generate_account_magic_link_token(account)
      refute account.confirmed_at

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/console"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account confirmed successfully."

      assert Accounts.get_account!(account.id).confirmed_at

      # Now do a logged in request and assert on the console chrome
      {:ok, _} = Accounts.create_workspace(account, %{name: "Test Workspace"})
      conn = get(conn, ~p"/console")
      response = html_response(conn, 200)
      assert response =~ account.email
      assert response =~ ~p"/accounts/settings"
      assert response =~ ~p"/accounts/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/accounts/log-in"
    end
  end

  describe "DELETE /accounts/log-out" do
    test "logs the account out", %{conn: conn, account: account} do
      conn = conn |> log_in_account(account) |> delete(~p"/accounts/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the account is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/accounts/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
