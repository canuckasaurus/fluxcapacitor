defmodule FluxWeb.Batch22WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  describe "SAML" do
    test "stays off until an IdP is configured" do
      refute FluxWeb.SAML.configured?()
    end

    test "the login page hides the SSO button when SAML is off", %{conn: conn} do
      response = conn |> get(~p"/accounts/log-in") |> html_response(200)
      refute response =~ "saml-login"
    end

    test "assertion_email prefers attribute emails and downcases" do
      assertion = %Samly.Assertion{
        attributes: %{"email" => "Doc.Brown@Example.com"},
        subject: %Samly.Subject{name: "some-opaque-id"}
      }

      assert FluxWeb.SAML.assertion_email(assertion) == {:ok, "doc.brown@example.com"}
    end

    test "assertion_email unwraps list-valued attributes and falls back through aliases" do
      assertion = %Samly.Assertion{
        attributes: %{"mail" => ["marty@example.com", "ignored@example.com"]},
        subject: nil
      }

      assert FluxWeb.SAML.assertion_email(assertion) == {:ok, "marty@example.com"}
    end

    test "assertion_email falls back to an email-shaped subject" do
      assertion = %Samly.Assertion{
        attributes: %{},
        subject: %Samly.Subject{name: "jennifer@example.com"}
      }

      assert FluxWeb.SAML.assertion_email(assertion) == {:ok, "jennifer@example.com"}
    end

    test "assertion_email refuses assertions without an email" do
      assertion = %Samly.Assertion{
        attributes: %{"email" => "not-an-address"},
        subject: %Samly.Subject{name: "opaque"}
      }

      assert FluxWeb.SAML.assertion_email(assertion) == {:error, :no_email}
      assert FluxWeb.SAML.assertion_email(nil) == {:error, :no_email}
    end

    test "hitting the completion route without an assertion bounces to log-in", %{conn: conn} do
      conn = get(conn, ~p"/auth/saml/complete")
      assert redirected_to(conn) == ~p"/accounts/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "No SAML session found"
    end
  end

  describe "session device info" do
    test "logging in records ip and browser on the session token", %{conn: conn} do
      account = set_password(account_fixture())

      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 TestBrowser/9.0")
        |> post(~p"/accounts/log-in", %{
          "account" => %{"email" => account.email, "password" => valid_account_password()}
        })

      assert redirected_to(conn)

      token =
        Flux.Repo.get_by!(Flux.Accounts.AccountToken,
          account_id: account.id,
          context: "session"
        )

      assert token.user_agent == "Mozilla/5.0 TestBrowser/9.0"
      assert token.ip == "127.0.0.1"
    end
  end
end
