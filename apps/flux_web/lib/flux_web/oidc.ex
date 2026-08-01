defmodule FluxWeb.OIDC do
  @moduledoc """
  Generic OpenID Connect login (authorization code flow) against any
  compliant provider — Google, Okta, Entra, Keycloak, Authentik, ….
  Configured entirely by environment (`FLUX_OIDC_ISSUER` /
  `FLUX_OIDC_CLIENT_ID` / `FLUX_OIDC_CLIENT_SECRET`); when unset, the
  login page shows no SSO button and the routes refuse.

  The id_token is verified locally: signature against the provider's
  JWKS (RS256/ES256/EdDSA), then issuer, audience, and expiry. Only the
  email claim is consumed — accounts are provisioned by address and
  arrive pre-confirmed (the IdP owns verification).
  """

  @allowed_algs ["RS256", "RS384", "RS512", "ES256", "ES384", "EdDSA"]
  @discovery_path "/.well-known/openid-configuration"

  def configured? do
    config()[:issuer] not in [nil, ""] and config()[:client_id] not in [nil, ""]
  end

  @doc "Label for the login button (FLUX_OIDC_NAME)."
  def provider_name, do: config()[:name] || "SSO"

  @doc "The provider URL to send the browser to."
  def authorize_url(redirect_uri, state) do
    with {:ok, discovery} <- discover() do
      query =
        URI.encode_query(%{
          "client_id" => config()[:client_id],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => "openid email profile",
          "state" => state
        })

      {:ok, discovery["authorization_endpoint"] <> "?" <> query}
    end
  end

  @doc "Redeems the callback code and returns the verified email."
  def exchange_code(code, redirect_uri) do
    with {:ok, discovery} <- discover(),
         {:ok, body} <- redeem(discovery, code, redirect_uri),
         id_token when is_binary(id_token) <-
           body["id_token"] || {:error, "the token response had no id_token"},
         {:ok, claims} <- verify_id_token(id_token, discovery) do
      validate_claims(claims)
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp redeem(discovery, code, redirect_uri) do
    options =
      req_options(
        url: discovery["token_endpoint"],
        form: [
          grant_type: "authorization_code",
          code: code,
          redirect_uri: redirect_uri,
          client_id: config()[:client_id],
          client_secret: config()[:client_secret] || ""
        ]
      )

    case Req.post(options) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "the token endpoint returned HTTP #{status}"}
      {:error, reason} -> {:error, "could not reach the token endpoint: #{inspect(reason)}"}
    end
  end

  defp verify_id_token(id_token, discovery) do
    case Req.get(req_options(url: discovery["jwks_uri"])) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        Enum.find_value(keys, {:error, "id_token signature verification failed"}, fn key ->
          case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), @allowed_algs, id_token) do
            {true, jwt, _jws} -> {:ok, jwt.fields}
            _no_match -> nil
          end
        end)

      _bad ->
        {:error, "could not fetch the provider's signing keys"}
    end
  end

  defp validate_claims(%{} = claims) do
    now = System.system_time(:second)

    cond do
      claims["iss"] != config()[:issuer] ->
        {:error, "id_token issuer mismatch"}

      config()[:client_id] not in List.wrap(claims["aud"]) ->
        {:error, "id_token audience mismatch"}

      not is_integer(claims["exp"]) or claims["exp"] < now ->
        {:error, "id_token is expired"}

      claims["email"] in [nil, ""] ->
        {:error, "the id_token carries no email claim"}

      true ->
        {:ok, String.downcase(claims["email"])}
    end
  end

  defp discover do
    url = String.trim_trailing(config()[:issuer] || "", "/") <> @discovery_path

    case Req.get(req_options(url: url)) do
      {:ok, %{status: 200, body: %{"authorization_endpoint" => _} = discovery}} ->
        {:ok, discovery}

      _bad ->
        {:error, "OIDC discovery failed — check FLUX_OIDC_ISSUER"}
    end
  end

  defp req_options(options) do
    Keyword.merge(options, Application.get_env(:flux_web, :oidc_req_options, []))
  end

  defp config, do: Application.get_env(:flux_web, __MODULE__, [])
end
