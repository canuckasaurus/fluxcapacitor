defmodule Flux.Plugin.Endpoint do
  @moduledoc """
  Behaviour for endpoint plugins: plugins that serve HTTP under a
  workspace-scoped URL (`/e/:installation-token/*path`). The platform
  authorizes the token, decrypts the workspace's credentials for the
  plugin, and hands the request over; the plugin returns a complete
  response. Useful for inbound integrations (Slack commands, custom
  webhook formats) and tiny plugin-served UIs.
  """

  @type credentials :: %{optional(String.t()) => String.t()}

  @type request :: %{
          method: String.t(),
          path: String.t(),
          query: %{optional(String.t()) => term()},
          body: term()
        }

  @type response :: %{status: pos_integer(), content_type: String.t(), body: binary()}

  @callback handle_request(credentials, request) :: {:ok, response} | {:error, term()}
end
