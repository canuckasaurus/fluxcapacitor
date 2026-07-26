defmodule Flux.ExAwsHttpClient do
  @moduledoc """
  Req-backed HTTP client for ExAws, so the whole app shares one HTTP stack
  (no hackney). Configured via `config :ex_aws, http_client: #{inspect(__MODULE__)}`.
  """
  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    opts = Keyword.get(http_opts, :req_opts, [])

    case Req.request(
           [
             method: method,
             url: url,
             body: body,
             headers: headers,
             decode_body: false,
             retry: false
           ] ++ opts
         ) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        flat_headers =
          for {name, values} <- resp_headers, value <- List.wrap(values), do: {name, value}

        {:ok, %{status_code: status, headers: flat_headers, body: resp_body}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end
end
