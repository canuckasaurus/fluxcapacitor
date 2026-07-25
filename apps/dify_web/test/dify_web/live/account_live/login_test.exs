defmodule DifyWeb.AccountLive.LoginTest do
  use DifyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Dify.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
      assert html =~ "Log in with email"
    end
  end

  describe "account login - magic link" do
    test "sends magic link email when account exists", %{conn: conn} do
      account = account_fixture()

      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", account: %{email: account.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If your email is in our system"

      assert Dify.Repo.get_by!(Dify.Accounts.AccountToken, account_id: account.id).context ==
               "login"
    end

    test "does not disclose if account is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", account: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "account login - password" do
    test "redirects if account logs in with valid credentials", %{conn: conn} do
      account = account_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      form =
        form(lv, "#login_form_password",
          account: %{email: account.email, password: valid_account_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      form =
        form(lv, "#login_form_password", account: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/accounts/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Sign up")
        |> render_click()
        |> follow_redirect(conn, ~p"/accounts/register")

      assert login_html =~ "Register"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      account = account_fixture()
      %{account: account, conn: log_in_account(conn, account)}
    end

    test "shows login page with email filled in", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Register"
      assert html =~ "Log in with email"

      assert html =~
               ~s(<input type="email" name="account[email]" id="login_form_magic_email" value="#{account.email}")
    end
  end
end
