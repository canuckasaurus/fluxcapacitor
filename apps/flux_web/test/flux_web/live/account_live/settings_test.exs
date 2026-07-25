defmodule FluxWeb.AccountLive.SettingsTest do
  use FluxWeb.ConnCase, async: true

  alias Flux.Accounts
  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_account(account_fixture())
        |> live(~p"/accounts/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if account is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/accounts/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if account is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_account(account_fixture(),
          token_authenticated_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/accounts/settings")
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      account = account_fixture()
      %{conn: log_in_account(conn, account), account: account}
    end

    test "updates the account email", %{conn: conn, account: account} do
      new_email = unique_account_email()

      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> form("#email_form", %{
          "account" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_account_by_email(account.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "account" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> form("#email_form", %{
          "account" => %{"email" => account.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      account = account_fixture()
      %{conn: log_in_account(conn, account), account: account}
    end

    test "updates the account password", %{conn: conn, account: account} do
      new_password = valid_account_password()

      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      form =
        form(lv, "#password_form", %{
          "account" => %{
            "email" => account.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/accounts/settings"

      assert get_session(new_password_conn, :account_token) != get_session(conn, :account_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_account_by_email_and_password(account.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "account" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      result =
        lv
        |> form("#password_form", %{
          "account" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      account = account_fixture()
      email = unique_account_email()

      token =
        extract_account_token(fn url ->
          Accounts.deliver_account_update_email_instructions(
            %{account | email: email},
            account.email,
            url
          )
        end)

      %{conn: log_in_account(conn, account), token: token, email: email, account: account}
    end

    test "updates the account email once", %{
      conn: conn,
      account: account,
      token: token,
      email: email
    } do
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_account_by_email(account.email)
      assert Accounts.get_account_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, account: account} do
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_account_by_email(account.email)
    end

    test "redirects if account is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/accounts/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/accounts/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
