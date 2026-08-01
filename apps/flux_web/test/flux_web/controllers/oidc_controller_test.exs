defmodule FluxWeb.OIDCControllerTest do
  use FluxWeb.ConnCase, async: false

  alias Flux.Accounts

  @issuer "https://sso.example.com"
  @client_id "flux-client"

  setup do
    Application.put_env(:flux_web, :oidc_req_options, plug: {Req.Test, Flux.OIDCStub})
    on_exit(fn -> Application.delete_env(:flux_web, :oidc_req_options) end)

    # A provider signing key (P-256 keeps test setup fast).
    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_meta, public_map} = JOSE.JWK.to_public_map(jwk)

    stub_provider = fn id_token ->
      Req.Test.stub(Flux.OIDCStub, fn conn ->
        case conn.request_path do
          "/.well-known/openid-configuration" ->
            Req.Test.json(conn, %{
              "authorization_endpoint" => @issuer <> "/authorize",
              "token_endpoint" => @issuer <> "/token",
              "jwks_uri" => @issuer <> "/jwks"
            })

          "/token" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            params = URI.decode_query(body)
            assert params["grant_type"] == "authorization_code"
            assert params["code"] == "good-code"
            assert params["client_secret"] == "flux-secret"
            Req.Test.json(conn, %{"id_token" => id_token})

          "/jwks" ->
            Req.Test.json(conn, %{"keys" => [public_map]})
        end
      end)
    end

    sign = fn claims ->
      {_meta, token} =
        jwk |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact()

      token
    end

    %{sign: sign, stub_provider: stub_provider}
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => @client_id,
        "exp" => System.system_time(:second) + 300,
        "sub" => "user-1",
        "email" => "SSO.User@example.com"
      },
      overrides
    )
  end

  defp start_flow(conn) do
    conn = get(conn, ~p"/auth/oidc")
    location = redirected_to(conn, 302)
    assert location =~ @issuer <> "/authorize?"
    %{"state" => state} = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {conn, state}
  end

  test "full login provisions a confirmed account and signs in", %{
    conn: conn,
    sign: sign,
    stub_provider: stub_provider
  } do
    stub_provider.(sign.(claims()))

    {conn, state} = start_flow(conn)

    conn = get(conn, ~p"/auth/oidc/callback?code=good-code&state=#{state}")
    assert redirected_to(conn) != ~p"/accounts/log-in"
    assert get_session(conn, :account_token)

    account = Accounts.get_account_by_email("sso.user@example.com")
    assert account.confirmed_at

    # A second login reuses the same account.
    stub_provider.(sign.(claims()))
    {conn2, state2} = start_flow(build_conn())
    conn2 = get(conn2, ~p"/auth/oidc/callback?code=good-code&state=#{state2}")
    assert get_session(conn2, :account_token)
    assert Accounts.get_account_by_email("sso.user@example.com").id == account.id
  end

  test "state mismatch and provider errors bounce back to login", %{
    conn: conn,
    sign: sign,
    stub_provider: stub_provider
  } do
    stub_provider.(sign.(claims()))
    {conn, _state} = start_flow(conn)

    bounced = get(conn, ~p"/auth/oidc/callback?code=good-code&state=wrong")
    assert redirected_to(bounced) == ~p"/accounts/log-in"
    assert Phoenix.Flash.get(bounced.assigns.flash, :error) =~ "session mismatch"

    # Provider-side refusal (no code param).
    denied = get(build_conn(), ~p"/auth/oidc/callback?error=access_denied")
    assert redirected_to(denied) == ~p"/accounts/log-in"
    assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "access_denied"
  end

  test "wrong audience and wrong issuer are rejected", %{
    conn: conn,
    sign: sign,
    stub_provider: stub_provider
  } do
    for bad <- [%{"aud" => "someone-else"}, %{"iss" => "https://evil.example.com"}] do
      stub_provider.(sign.(claims(bad)))
      _keep = conn
      {flow_conn, state} = start_flow(build_conn())
      bounced = get(flow_conn, ~p"/auth/oidc/callback?code=good-code&state=#{state}")
      assert redirected_to(bounced) == ~p"/accounts/log-in"
      assert Phoenix.Flash.get(bounced.assigns.flash, :error) =~ "mismatch"
    end

    assert Accounts.get_account_by_email("sso.user@example.com") == nil
  end

  test "tokens signed by an unknown key are rejected", %{
    conn: conn,
    stub_provider: stub_provider
  } do
    rogue = JOSE.JWK.generate_key({:ec, :secp256r1})

    {_meta, forged} =
      rogue |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims()) |> JOSE.JWS.compact()

    stub_provider.(forged)
    {conn, state} = start_flow(conn)

    bounced = get(conn, ~p"/auth/oidc/callback?code=good-code&state=#{state}")
    assert redirected_to(bounced) == ~p"/accounts/log-in"
    assert Phoenix.Flash.get(bounced.assigns.flash, :error) =~ "signature"
  end

  test "the login page offers the configured provider", %{conn: conn} do
    html = conn |> get(~p"/accounts/log-in") |> html_response(200)
    assert html =~ "Continue with Example SSO"
    assert html =~ "/auth/oidc"
  end
end
