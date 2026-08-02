defmodule Flux.Engine.Docx do
  @moduledoc """
  Fills Word (.docx) templates carrying Jinja tags — the document layer
  for docassemble-style assembly. A docx is a zip of XML parts; render:

  1. unzip in memory; take the text parts (document, headers, footers)
  2. repair tags Word fragmented across text runs — the span of runs
     containing a split `{{ … }}` / `{% … %}` collapses onto the run
     where the tag starts, preserving formatting everywhere else
  3. normalize the curly quotes Word autocorrects inside tags
  4. lift block tags: a paragraph whose entire text is `{%p … %}`
     becomes a bare Jinja tag replacing the whole paragraph (so
     conditionals/loops can add or remove paragraphs); `{%tr … %}` does
     the same for a table row
  5. render the whole XML through the Jinja engine with XML-escaped
     interpolation (newlines in values become `<w:br/>`)
  6. zip everything back up

  Pure — bytes in, bytes out. Tags Word has broken beyond repair (e.g.
  interleaved with tracked changes) surface as loud errors, not silent
  mis-renders.
  """

  alias Flux.Engine.Jinja

  @text_part ~r{^word/(document|header\d*|footer\d*)\.xml$}
  @w_t ~r{<w:t(?:\s[^>]*)?>[^<]*</w:t>}s
  @paragraph ~r{<w:p[\s>].*?</w:p>}s
  @table_row ~r{<w:tr[\s>].*?</w:tr>}s

  @doc "Renders a docx template binary against a variable context."
  @spec render(binary(), map()) :: {:ok, binary()} | {:error, String.t()}
  def render(docx_binary, context) when is_binary(docx_binary) and is_map(context) do
    with {:ok, entries} <- unzip(docx_binary) do
      results =
        Enum.map(entries, fn {name, content} ->
          if text_part?(name) do
            with {:ok, rendered} <- render_part(content, context), do: {:ok, {name, rendered}}
          else
            {:ok, {name, content}}
          end
        end)

      case Enum.find(results, &match?({:error, _message}, &1)) do
        {:error, message} -> {:error, message}
        nil -> rezip(Enum.map(results, fn {:ok, entry} -> entry end))
      end
    end
  end

  @doc """
  The root variable names a template references — for upload validation
  and for scaffolding an interview form. Also validates the Jinja.
  """
  @spec extract_tags(binary()) :: {:ok, [String.t()]} | {:error, String.t()}
  def extract_tags(docx_binary) when is_binary(docx_binary) do
    with {:ok, entries} <- unzip(docx_binary) do
      entries
      |> Enum.filter(fn {name, _content} -> text_part?(name) end)
      |> Enum.reduce_while({:ok, MapSet.new()}, fn {_name, content}, {:ok, acc} ->
        prepared = prepare(content)

        case Jinja.render(prepared, %{}) do
          {:ok, _rendered} -> {:cont, {:ok, MapSet.union(acc, tags_in(prepared))}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
      |> case do
        {:ok, tags} -> {:ok, Enum.sort(tags)}
        {:error, message} -> {:error, message}
      end
    end
  end

  ## Zip plumbing

  defp unzip(binary) do
    case :zip.unzip(binary, [:memory]) do
      {:ok, [_entry | _rest] = entries} ->
        if List.keyfind(entries, ~c"word/document.xml", 0) do
          {:ok, entries}
        else
          {:error, "not a Word document (no word/document.xml inside)"}
        end

      _error ->
        {:error, "not a .docx file (could not read the zip archive)"}
    end
  end

  defp rezip(entries) do
    case :zip.create(~c"filled.docx", entries, [:memory]) do
      {:ok, {_name, binary}} -> {:ok, binary}
      _error -> {:error, "could not rebuild the document archive"}
    end
  end

  defp text_part?(name), do: Regex.match?(@text_part, to_string(name))

  ## Rendering one XML part

  defp render_part(content, context) do
    prepared = prepare(content)

    case Jinja.render(prepared, context, escape: &escape_value/1) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, message} -> {:error, "docx template error: " <> message}
    end
  end

  defp prepare(content) do
    content
    |> to_string()
    |> merge_split_runs()
    |> lift_block_tags()
  end

  defp escape_value(text) do
    text
    |> xml_escape()
    |> String.replace("\n", ~s(</w:t><w:br/><w:t xml:space="preserve">))
  end

  defp xml_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp xml_unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  ## Step 2+3 — repair tags Word split across runs, per paragraph.

  defp merge_split_runs(xml) do
    Regex.replace(@paragraph, xml, fn paragraph ->
      if paragraph =~ "{" do
        merge_paragraph(paragraph)
      else
        paragraph
      end
    end)
  end

  defp merge_paragraph(paragraph) do
    chunks = Regex.split(@w_t, paragraph, include_captures: true)
    texts = for chunk <- chunks, text_chunk?(chunk), do: inner_text(chunk)
    combined = Enum.join(texts)

    if combined =~ "{" do
      spans = tag_spans(combined)
      new_texts = reassign(texts, combined, spans)
      rebuild(chunks, new_texts)
    else
      paragraph
    end
  end

  defp text_chunk?(chunk), do: String.starts_with?(chunk, "<w:t")

  defp inner_text(chunk), do: Regex.replace(~r{^<w:t(?:\s[^>]*)?>|</w:t>$}s, chunk, "")

  # Character spans of {{ … }} / {% … %} / {# … #} tags in the combined
  # paragraph text, with Word's curly quotes normalized inside them.
  defp tag_spans(text) do
    ~r/\{\{.*?\}\}|\{%.*?%\}|\{#.*?#\}/s
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, length}] -> {start, start + length} end)
  end

  # Every character keeps its original run — except characters inside a
  # tag span, which all move to the run where the span starts.
  defp reassign(texts, combined, spans) do
    boundaries =
      texts
      |> Enum.map(&String.length/1)
      |> Enum.scan(0, &(&1 + &2))

    owner_of = fn position -> Enum.count(boundaries, &(&1 <= position)) end

    combined
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(List.duplicate("", length(texts)), fn {char, position}, acc ->
      span = Enum.find(spans, fn {from, to} -> position >= from and position < to end)
      owner = if span, do: owner_of.(elem(span, 0)), else: owner_of.(position)
      char = if span, do: straighten(char), else: char
      List.update_at(acc, owner, &(&1 <> char))
    end)
  end

  defp straighten(char) when char in ["“", "”"], do: "\""
  defp straighten(char) when char in ["‘", "’"], do: "'"
  defp straighten(char), do: char

  defp rebuild(chunks, new_texts) do
    {rebuilt, []} =
      Enum.map_reduce(chunks, new_texts, fn chunk, remaining ->
        if text_chunk?(chunk) do
          [text | rest] = remaining
          open = chunk |> String.split(">", parts: 2) |> hd()
          open = ensure_preserve(open <> ">")
          {open <> text <> "</w:t>", rest}
        else
          {chunk, remaining}
        end
      end)

    Enum.join(rebuilt)
  end

  defp ensure_preserve(open_tag) do
    if open_tag =~ "xml:space" do
      open_tag
    else
      String.replace_suffix(open_tag, ">", ~s( xml:space="preserve">))
    end
  end

  ## Step 4 — paragraph/table-row tags become bare Jinja tags.

  defp lift_block_tags(xml) do
    xml
    |> lift(@table_row, "tr")
    |> lift(@paragraph, "p")
  end

  defp lift(xml, element_pattern, marker) do
    Regex.replace(element_pattern, xml, fn element ->
      text = element |> strip_xml_text() |> xml_unescape() |> String.trim()

      case Regex.run(~r/^\{%#{marker}\s+(.+?)\s*%\}$/s, text) do
        [_whole, tag] -> "{% " <> tag <> " %}"
        nil -> element
      end
    end)
  end

  # The concatenated visible text of an XML fragment.
  defp strip_xml_text(xml) do
    @w_t
    |> Regex.scan(xml)
    |> Enum.map_join(fn [chunk] -> inner_text(chunk) end)
  end

  ## Tag extraction (over prepared XML)

  @keywords ~w(if elif else endif for endfor in and or not true false True False loop none None)

  defp tags_in(prepared_xml) do
    text = strip_xml_text(prepared_xml) <> block_tag_text(prepared_xml)

    output_roots =
      ~r/\{\{(.*?)\}\}/s
      |> Regex.scan(text)
      |> Enum.flat_map(fn [_whole, expr] ->
        expr |> String.split("|") |> hd() |> identifier_roots()
      end)

    {loop_vars, control_roots} =
      ~r/\{%\s*(.*?)\s*%\}/s
      |> Regex.scan(text)
      |> Enum.reduce({MapSet.new(), []}, fn [_whole, tag], {vars, roots} ->
        case Regex.run(~r/^for\s+([A-Za-z_]\w*)\s+in\s+(.+)$/s, tag) do
          [_whole, var, source] ->
            {MapSet.put(vars, var), identifier_roots(source) ++ roots}

          nil ->
            {vars, identifier_roots(tag) ++ roots}
        end
      end)

    (output_roots ++ control_roots)
    |> MapSet.new()
    |> MapSet.difference(loop_vars)
    |> MapSet.difference(MapSet.new(@keywords))
  end

  # Bare {% … %} tags produced by lifting live outside <w:t> elements.
  defp block_tag_text(prepared_xml) do
    ~r/\{%[^<]*?%\}/s
    |> Regex.scan(prepared_xml)
    |> Enum.map_join(" ", fn [tag] -> tag end)
  end

  defp identifier_roots(expression) do
    without_strings = Regex.replace(~r/"[^"]*"|'[^']*'/, expression, " ")

    ~r/[A-Za-z_]\w*(?:\.\w+)*/
    |> Regex.scan(without_strings)
    |> Enum.map(fn [path] -> path |> String.split(".") |> hd() end)
    |> Enum.reject(&(&1 in @keywords))
  end
end
