defmodule Flux.Documents do
  @moduledoc """
  Text extraction from uploaded files for the document-extractor node.

  Native formats — plain text, markdown, CSV, JSON, HTML (tags stripped
  via floki), and Word .docx (zipped XML, read directly). Everything else
  (xlsx, pptx, legacy .doc, PDF…) goes through `Flux.Tika` when a server
  is configured, and fails with an honest error when not.
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
      docx?(file) ->
        docx_text(binary)

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

      Flux.Tika.configured?() ->
        Flux.Tika.extract(binary, file.content_type)

      true ->
        {:error,
         "unsupported content type #{file.content_type || "unknown"} — " <>
           "office formats need Tika (set FLUX_TIKA_URL; the `rag` compose profile runs one)"}
    end
  end

  defp html?(%{content_type: type, name: name}) do
    (type || "") =~ "html" or Path.extname(name || "") in [".html", ".htm"]
  end

  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  defp docx?(%{content_type: type, name: name}) do
    type == @docx_type or String.downcase(Path.extname(name || "")) == ".docx"
  end

  # Native .docx text: a docx is zipped XML — paragraphs become lines,
  # runs concatenate. No Tika needed for Word files.
  defp docx_text(binary) do
    with {:ok, entries} <- unzip_docx(binary),
         {_name, xml} <- List.keyfind(entries, ~c"word/document.xml", 0) do
      text =
        xml
        |> to_string()
        |> String.replace(~r{</w:p>}, "\n")
        |> then(fn with_breaks ->
          ~r{<w:t(?:\s[^>]*)?>([^<]*)</w:t>|\n}
          |> Regex.scan(with_breaks)
          |> Enum.map_join(fn
            ["\n"] -> "\n"
            [_whole, inner] -> xml_unescape(inner)
          end)
        end)
        |> String.replace(~r/\n{3,}/, "\n\n")
        |> String.trim()

      {:ok, text}
    else
      _not_a_docx -> {:error, "could not read the Word document"}
    end
  end

  defp unzip_docx(binary) do
    case :zip.unzip(binary, [:memory]) do
      {:ok, entries} -> {:ok, entries}
      _error -> {:error, :bad_zip}
    end
  end

  defp xml_unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  @textual_extensions ~w(.txt .md .markdown .csv .tsv .json .xml .yml .yaml .log)

  defp textual?(%{content_type: type, name: name}) do
    String.starts_with?(type || "", "text/") or
      (type || "") in ["application/json", "application/xml", "application/x-yaml"] or
      Path.extname(name || "") in @textual_extensions
  end
end
