defmodule FluxWeb.PageControllerTest do
  use FluxWeb.ConnCase, async: true

  import Flux.AccountsFixtures

  test "GET / renders the public landing page", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "FluxCapacitor"
    assert response =~ "Build AI-powered workflows"
    assert response =~ "How it works"
    assert response =~ ~p"/accounts/register"
  end

  test "GET / redirects authenticated accounts to the console", %{conn: conn} do
    account = account_fixture()
    conn = conn |> log_in_account(account) |> get(~p"/")
    assert redirected_to(conn) == ~p"/console"
  end
end
