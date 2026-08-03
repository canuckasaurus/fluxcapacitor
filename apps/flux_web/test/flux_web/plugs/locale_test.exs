defmodule FluxWeb.Plugs.LocaleTest do
  use FluxWeb.ConnCase, async: true

  test "resolves the locale from Accept-Language, matching base languages", %{conn: conn} do
    # fr-CA has no exact catalog, but the shipped fr one base-matches.
    conn =
      conn
      |> put_req_header("accept-language", "fr-CA, en-US;q=0.8")
      |> get(~p"/accounts/log-in")

    assert get_session(conn, :locale) == "fr"
    assert html_response(conn, 200) =~ "Se connecter"
  end

  test "Accept-Language with no matching catalog falls back to English", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "de-DE, es;q=0.8")
      |> get(~p"/accounts/log-in")

    assert get_session(conn, :locale) == nil
    assert html_response(conn, 200) =~ "Log in"
  end

  test "an unknown ?locale= is ignored rather than crashing", %{conn: conn} do
    conn = get(conn, ~p"/accounts/log-in?locale=xx")

    assert get_session(conn, :locale) == nil
    assert html_response(conn, 200)
  end
end
