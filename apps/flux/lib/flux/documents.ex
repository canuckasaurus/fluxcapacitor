defmodule Flux.Documents do
  @moduledoc """
  Text extraction from uploaded files for the document-extractor node.

  Native formats only for now — plain text, markdown, CSV, JSON, and HTML
  (tags stripped via floki). Office formats arrive with the Tika sidecar
  in the Docker stack (WS3).
  """

  alias Flux.Chat.UploadedFile
  alias Flux.Repo

  @max_text_bytes 2_000_000

  @doc "Extracts text from an uploaded file, workspace-checked by id."
  def extract(workspace_id, file_id) do
    with {:ok, file} <- fetch(workspace_id, file_id),
         {:ok, binary} <- Flux.Storage.get(file.key),
         {:ok, text} <- to_text(file, binary) do
      {:ok, %{text: String.slice(text, 0, @max_text_bytes), name: file.name, size: file.size}}
    end
  end

  defp fetch(workspace_id, file_id) do
    case Ecto.UUID.cast(to_string(file_id)) do
      {:ok, id} ->
        case Repo.get_by(UploadedFile, [id: id, workspace_id: workspace_id],
               skip_workspace_guard: true
             ) do
          %UploadedFile{} = file -> {:ok, file}
          nil -> {:error, "file not found"}
        end

      :error ->
        {:error, "not a file id: #{inspect(file_id)}"}
    end
  end

  defp to_text(file, binary) do
    cond do
      html?(file) ->
        case Floki.parse_document(binary) do
          {:ok, document} -> {:ok, document |> Floki.text(sep: " ") |> String.trim()}
          {:error, _reason} -> {:error, "could not parse the HTML document"}
        end

      textual?(file) ->
        if String.valid?(binary) do
          {:ok, binary}
        else
          {:error, "#{file.name} is not valid UTF-8 text"}
        end

      true ->
        {:error,
         "unsupported content type #{file.content_type || "unknown"} — " <>
           "office formats need the Tika sidecar (Docker stack)"}
    end
  end

  defp html?(%{content_type: type, name: name}) do
    (type || "") =~ "html" or Path.extname(name || "") in [".html", ".htm"]
  end

  @textual_extensions ~w(.txt .md .markdown .csv .tsv .json .xml .yml .yaml .log)

  defp textual?(%{content_type: type, name: name}) do
    String.starts_with?(type || "", "text/") or
      (type || "") in ["application/json", "application/xml", "application/x-yaml"] or
      Path.extname(name || "") in @textual_extensions
  end
end
