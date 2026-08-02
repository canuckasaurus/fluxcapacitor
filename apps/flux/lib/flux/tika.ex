defmodule Flux.Tika do
  @moduledoc """
  Text extraction through an Apache Tika server — the `rag` compose
  profile, or any `FLUX_TIKA_URL` deployment. Covers the office formats
  `Flux.Documents` cannot read natively (xlsx, pptx, legacy .doc, PDF…).
  Optional by design: without a server the caller keeps its honest
  "unsupported format" error. Tests inject `module:` config.
  """

  @doc "Whether an extractor (module or URL) is configured."
  def configured? do
    config()[:module] != nil or to_string(config()[:url] || "") != ""
  end

  @doc "Extracts plain text from a document binary."
  def extract(binary, content_type \\ nil) when is_binary(binary) do
    cond do
      module = config()[:module] ->
        module.extract(binary, content_type)

      (url = to_string(config()[:url] || "")) != "" ->
        request_extraction(url, binary, content_type)

      true ->
        {:error,
         "office formats need a Tika server — set FLUX_TIKA_URL " <>
           "(the `rag` compose profile runs one)"}
    end
  end

  defp request_extraction(base_url, binary, content_type) do
    url = String.trim_trailing(base_url, "/") <> "/tika"

    headers =
      [{"accept", "text/plain"}] ++
        if content_type not in [nil, ""], do: [{"content-type", content_type}], else: []

    case Req.put(url, body: binary, headers: headers, receive_timeout: 120_000, retry: false) do
      {:ok, %{status: 200, body: text}} when is_binary(text) ->
        {:ok, String.trim(text)}

      {:ok, %{status: 422}} ->
        {:error, "Tika could not parse this document (unsupported or corrupt format)"}

      {:ok, %{status: status}} ->
        {:error, "the Tika server answered HTTP #{status}"}

      {:error, exception} ->
        {:error, "could not reach the Tika server: " <> Exception.message(exception)}
    end
  end

  defp config, do: Application.get_env(:flux, __MODULE__, [])
end
