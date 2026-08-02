defmodule Flux.Pdf do
  @moduledoc """
  DOCX → PDF conversion through a Gotenberg-compatible converter — the
  `documents` compose profile, or any `FLUX_PDF_URL` deployment.
  Optional by design: with no converter configured, PDF output fails
  loudly and Word output is unaffected. Tests inject `module:` config.
  """

  @doc "Whether a converter (module or URL) is configured."
  def configured? do
    config()[:module] != nil or to_string(config()[:url] || "") != ""
  end

  @doc "Converts docx bytes to PDF bytes."
  def convert_docx(binary) when is_binary(binary) do
    cond do
      module = config()[:module] ->
        module.convert_docx(binary)

      (url = to_string(config()[:url] || "")) != "" ->
        request_conversion(url, binary)

      true ->
        {:error,
         "PDF output needs a converter — set FLUX_PDF_URL " <>
           "(the `documents` compose profile runs Gotenberg)"}
    end
  end

  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  defp request_conversion(base_url, binary) do
    url = String.trim_trailing(base_url, "/") <> "/forms/libreoffice/convert"
    boundary = "flux" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    body =
      "--#{boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"files\"; filename=\"template.docx\"\r\n" <>
        "Content-Type: #{@docx_type}\r\n\r\n" <>
        binary <> "\r\n--#{boundary}--\r\n"

    headers = [{"content-type", "multipart/form-data; boundary=#{boundary}"}]

    case Req.post(url, body: body, headers: headers, receive_timeout: 60_000, retry: false) do
      {:ok, %{status: 200, body: pdf}} when is_binary(pdf) ->
        {:ok, pdf}

      {:ok, %{status: status}} ->
        {:error, "the PDF converter answered HTTP #{status}"}

      {:error, exception} ->
        {:error, "could not reach the PDF converter: " <> Exception.message(exception)}
    end
  end

  defp config, do: Application.get_env(:flux, __MODULE__, [])
end
