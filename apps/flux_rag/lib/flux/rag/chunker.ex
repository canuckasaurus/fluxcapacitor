defmodule Flux.RAG.Chunker do
  @moduledoc """
  Splits document text into overlapping segments. Paragraphs are packed
  greedily up to `max_chars`; oversized paragraphs fall back to sentence
  packing, then to a hard split. `overlap` characters of the previous
  chunk's tail prefix each following chunk for context continuity.
  """

  @default_max 1_000
  @default_overlap 120

  def split(text, opts \\ []) do
    if Keyword.get(opts, :markdown, false) do
      split_markdown(text, opts)
    else
      split_plain(text, opts)
    end
  end

  defp split_plain(text, opts) do
    max_chars = Keyword.get(opts, :max_chars, @default_max)
    overlap = Keyword.get(opts, :overlap, @default_overlap)

    text
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.flat_map(&explode(&1, max_chars))
    |> pack([], "", max_chars)
    |> apply_overlap(overlap)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  @doc """
  Markdown-aware splitting: the text first divides at headings, each
  section chunks independently, and every chunk carries its heading as a
  prefix — retrieval hits keep their document context.
  """
  def split_markdown(text, opts \\ []) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split(~r/^(?=\#{1,6}[ \t])/m, trim: true)
    |> Enum.flat_map(fn section ->
      case String.split(section, "\n", parts: 2) do
        [heading, body] ->
          if heading =~ ~r/^\#{1,6}[ \t]/ do
            body
            |> split_plain(Keyword.put(opts, :markdown, false))
            |> Enum.map(&(String.trim(heading) <> "\n\n" <> &1))
          else
            split_plain(section, Keyword.put(opts, :markdown, false))
          end

        [_only_line] ->
          split_plain(section, Keyword.put(opts, :markdown, false))
      end
    end)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  @doc """
  Parent-child splitting: parents are normal chunks at `max_chars`;
  each parent then splits into children at a quarter of that size (at
  least 200 chars). Returns `{child, parent}` pairs — the child is what
  gets embedded, the parent is what retrieval should hand to the model.
  """
  def split_parent_child(text, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, @default_max)
    child_chars = max(div(max_chars, 4), 200)

    text
    |> split(Keyword.put(opts, :overlap, 0))
    |> Enum.flat_map(fn parent ->
      parent
      |> split_plain(max_chars: child_chars, overlap: 0, markdown: false)
      |> Enum.map(&{&1, parent})
    end)
  end

  # A paragraph larger than max_chars splits on sentences, then hard-wraps.
  defp explode(paragraph, max_chars) do
    if String.length(paragraph) <= max_chars do
      [paragraph]
    else
      paragraph
      |> String.split(~r/(?<=[.!?])\s+/, trim: true)
      |> Enum.flat_map(fn sentence ->
        if String.length(sentence) <= max_chars do
          [sentence]
        else
          sentence |> String.codepoints() |> Enum.chunk_every(max_chars) |> Enum.map(&Enum.join/1)
        end
      end)
    end
  end

  defp pack([], chunks, "", _max), do: Enum.reverse(chunks)
  defp pack([], chunks, current, _max), do: Enum.reverse([current | chunks])

  defp pack([piece | rest], chunks, current, max_chars) do
    candidate = if current == "", do: piece, else: current <> "\n\n" <> piece

    if String.length(candidate) <= max_chars do
      pack(rest, chunks, candidate, max_chars)
    else
      pack(rest, [current | chunks], piece, max_chars)
    end
  end

  defp apply_overlap(chunks, overlap) when overlap <= 0, do: chunks
  defp apply_overlap([], _overlap), do: []

  defp apply_overlap([first | rest], overlap) do
    {reversed, _previous} =
      Enum.reduce(rest, {[first], first}, fn chunk, {acc, previous} ->
        tail = String.slice(previous, -overlap, overlap)
        {["…" <> tail <> "\n" <> chunk | acc], chunk}
      end)

    Enum.reverse(reversed)
  end
end
