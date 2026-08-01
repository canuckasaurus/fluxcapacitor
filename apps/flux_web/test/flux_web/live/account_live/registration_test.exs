defmodule FluxWeb.AccountLive.RegistrationTest do
  use FluxWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/register")

      assert html =~ "Create an account"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_account(account_fixture())
        |> live(~p"/accounts/register")
        |> follow_redirect(conn, ~p"/console")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(account: %{"email" => "with spaces"})

      assert result =~ "Create an account"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register account" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      email = unique_account_email()
      form = form(lv, "#registration_form", account: valid_account_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      account = account_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          account: %{"email" => account.email}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert login_html =~ "Log in"
    end
  end
end
