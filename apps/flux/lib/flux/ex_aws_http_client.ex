defmodule Flux.ExAwsHttpClient do
  @moduledoc """
  Req-backed HTTP client for ExAws, so the whole app shares one HTTP stack
  (no hackney). Configured via `config :ex_aws, http_client: #{inspect(__MODULE__)}`.
  """
  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    opts = Keyword.get(http_opts, :req_opts, [])

    # Req 0.7 infers POST whenever a :body option is present — even an empty
    # string with an explicit :method — which turns S3 GET/DELETE into POST.
    # Only pass :body when there is one.
    body_opts = if body in [nil, ""], do: [], else: [body: body]

    case Req.request(
           [
             method: method,
             url: url,
             headers: headers,
             decode_body: false,
             retry: false
           ] ++ body_opts ++ opts
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
