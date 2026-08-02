defmodule FluxWeb.FileController do
  @moduledoc """
  Run-file downloads. The unguessable `file_…` token minted at store
  time is the authorization, so the same URL works from the console,
  public sites, and API responses.
  """
  use FluxWeb, :controller

  def download(conn, %{"token" => token}) do
    case Flux.Workflows.fetch_file_by_token(token) do
      {:ok, %{name: name, content_type: content_type, binary: binary}} ->
        send_download(conn, {:binary, binary},
          filename: name,
          content_type: content_type || "application/octet-stream"
        )

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
    end
  end
end
