defmodule FluxWeb.SAML do
  @moduledoc """
  SAML 2.0 single sign-on (service-provider side, via Samly/esaml).

  Enabled when `SAML_IDP_METADATA_FILE` points at the IdP's metadata XML
  (mount it into the container). Companion vars: `SAML_SP_ENTITY_ID`
  (defaults to the app URL), and `SAML_SP_KEY`/`SAML_SP_CERT` (PEM
  paths) when the IdP requires signed requests — generate a pair with
  `openssl req -x509 -newkey rsa:2048 -nodes -days 1095`.

  The IdP should POST assertions to `<base>/sso/sp/consume/idp` and use
  `<base>/sso/sp/metadata/idp` as the SP metadata URL. Provisioned
  accounts join like OIDC ones (`get_or_register_sso_account`).
  """

  def configured? do
    Application.get_env(:samly, Samly.Provider, [])
    |> Keyword.get(:identity_providers, [])
    |> Enum.any?()
  end

  @doc "The email carried by a SAML assertion (subject or common attributes)."
  def assertion_email(%Samly.Assertion{} = assertion) do
    candidates =
      [
        assertion.attributes["email"],
        assertion.attributes["mail"],
        assertion.attributes["urn:oid:0.9.2342.19200300.100.1.3"],
        assertion.attributes[
          "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
        ],
        assertion.subject && assertion.subject.name
      ]
      |> Enum.map(&extract_value/1)
      |> Enum.filter(&(is_binary(&1) and String.contains?(&1, "@")))

    case candidates do
      [email | _rest] -> {:ok, String.downcase(email)}
      [] -> {:error, :no_email}
    end
  end

  def assertion_email(_other), do: {:error, :no_email}

  defp extract_value([value | _rest]), do: extract_value(value)
  defp extract_value(value) when is_binary(value), do: value
  defp extract_value(value) when is_list(value), do: nil
  defp extract_value(_other), do: nil
end
