defmodule Flux.CSV do
  @moduledoc """
  Small RFC-4180 CSV codec (quoted fields, embedded commas/newlines,
  doubled quotes) — enough for batch-run uploads and result downloads
  without pulling in a dependency.
  """

  @doc "Parses CSV text into a list of rows (lists of string fields)."
  def parse(text) when is_binary(text) do
    text
    |> String.replace_prefix("﻿", "")
    |> parse_rows([], [], "")
  end

  @doc """
  Parses CSV text whose first row is a header into a list of
  `%{column => value}` maps. Blank rows are dropped.
  """
  def parse_with_header(text) do
    case parse(text) do
      [] ->
        {:error, :empty}

      [header | rows] ->
        header = Enum.map(header, &String.trim/1)

        if Enum.any?(header, &(&1 == "")) or header == [] do
          {:error, :invalid_header}
        else
          maps =
            for row <- rows, Enum.any?(row, &(String.trim(&1) != "")) do
              header |> Enum.zip(pad(row, length(header))) |> Map.new()
            end

          {:ok, maps}
        end
    end
  end

  @doc "Encodes rows (lists of terms) as CRLF-delimited CSV text."
  def encode(rows) when is_list(rows) do
    Enum.map_join(rows, "\r\n", fn row ->
      Enum.map_join(row, ",", &encode_field/1)
    end) <> "\r\n"
  end

  @doc """
  Escapes one value as a CSV field: RFC-4180 quoting plus a
  **formula-injection guard** — a value that starts with a spreadsheet
  formula trigger (`= + - @`, tab, or CR) is prefixed with a single
  quote so Excel/Sheets treat it as text, not code. Visitor-controlled
  strings (chat messages, conversation titles) land in operator CSV
  exports, so this is the single choke point every builder must use.
  """
  def encode_field(nil), do: ""

  def encode_field(value) do
    text = value |> to_string() |> guard_formula()

    if String.contains?(text, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(text, "\"", "\"\"") <> "\""
    else
      text
    end
  end

  @formula_triggers ["=", "+", "-", "@", "\t", "\r"]

  defp guard_formula(<<first::utf8, _rest::binary>> = text)
       when <<first::utf8>> in @formula_triggers,
       do: "'" <> text

  defp guard_formula(text), do: text

  defp pad(row, size) when length(row) >= size, do: Enum.take(row, size)
  defp pad(row, size), do: row ++ List.duplicate("", size - length(row))

  # A hand-rolled scanner: `rows` and `fields` accumulate in reverse.
  defp parse_rows(<<"\"", rest::binary>>, rows, fields, ""),
    do: parse_quoted(rest, rows, fields, "")

  defp parse_rows(<<",", rest::binary>>, rows, fields, field),
    do: parse_rows(rest, rows, [field | fields], "")

  defp parse_rows(<<"\r\n", rest::binary>>, rows, fields, field),
    do: parse_rows(rest, [Enum.reverse([field | fields]) | rows], [], "")

  defp parse_rows(<<"\n", rest::binary>>, rows, fields, field),
    do: parse_rows(rest, [Enum.reverse([field | fields]) | rows], [], "")

  defp parse_rows(<<char::utf8, rest::binary>>, rows, fields, field),
    do: parse_rows(rest, rows, fields, field <> <<char::utf8>>)

  defp parse_rows(<<>>, rows, [], ""), do: Enum.reverse(rows)

  defp parse_rows(<<>>, rows, fields, field),
    do: Enum.reverse([Enum.reverse([field | fields]) | rows])

  defp parse_quoted(<<"\"\"", rest::binary>>, rows, fields, field),
    do: parse_quoted(rest, rows, fields, field <> "\"")

  defp parse_quoted(<<"\"", rest::binary>>, rows, fields, field),
    do: parse_rows(rest, rows, fields, field)

  defp parse_quoted(<<char::utf8, rest::binary>>, rows, fields, field),
    do: parse_quoted(rest, rows, fields, field <> <<char::utf8>>)

  # Unterminated quote: treat what we have as the final field.
  defp parse_quoted(<<>>, rows, fields, field),
    do: parse_rows(<<>>, rows, fields, field)
end
