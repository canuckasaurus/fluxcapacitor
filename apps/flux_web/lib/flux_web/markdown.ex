defmodule FluxWeb.Markdown do
  @moduledoc """
  Markdown for chat bubbles — model output is untrusted, so this renderer
  is safe by construction: every character of source text goes through
  `Phoenix.HTML.html_escape/1` before any tag is emitted, raw HTML never
  passes through, and links are restricted to http/https. Deliberately
  small (headings, lists, quotes, fences, inline code/bold/italic/links);
  the docs viewer keeps Earmark for trusted compile-time content.
  """

  import Phoenix.HTML, only: [html_escape: 1, safe_to_string: 1]

  @doc "Renders untrusted markdown to a `{:safe, iodata}` HTML fragment."
  def render(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> blocks([])
    |> Enum.reverse()
    |> Enum.join("\n")
    |> then(&{:safe, &1})
  end

  def render(_other), do: {:safe, ""}

  # -- block structure ----------------------------------------------------

  defp blocks([], acc), do: acc

  defp blocks([<<"```", lang::binary>> | rest], acc) do
    {code, rest} = take_fence(rest, [])
    lang = lang |> String.trim() |> escape()

    block =
      ~s(<pre class="chat-code"><code class="language-#{lang}">) <>
        escape(Enum.join(code, "\n")) <> "</code></pre>"

    blocks(rest, [block | acc])
  end

  defp blocks([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        blocks(rest, acc)

      heading?(line) ->
        {level, text} = split_heading(line)
        blocks(rest, ["<h#{level}>#{inline(text)}</h#{level}>" | acc])

      String.match?(line, ~r/^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/) ->
        blocks(rest, ["<hr/>" | acc])

      quote?(line) ->
        {lines, rest} = take_while_prefix(rest, &quote?/1, &strip_quote/1, [strip_quote(line)])
        body = lines |> Enum.map_join("<br/>", &inline/1)
        blocks(rest, ["<blockquote>#{body}</blockquote>" | acc])

      bullet?(line) ->
        {items, rest} = take_while_prefix(rest, &bullet?/1, &strip_bullet/1, [strip_bullet(line)])
        body = items |> Enum.map_join("", &"<li>#{inline(&1)}</li>")
        blocks(rest, ["<ul>#{body}</ul>" | acc])

      ordered?(line) ->
        {items, rest} =
          take_while_prefix(rest, &ordered?/1, &strip_ordered/1, [strip_ordered(line)])

        body = items |> Enum.map_join("", &"<li>#{inline(&1)}</li>")
        blocks(rest, ["<ol>#{body}</ol>" | acc])

      true ->
        {lines, rest} = take_while_prefix(rest, &paragraph?/1, & &1, [line])
        body = lines |> Enum.map_join("<br/>", &inline/1)
        blocks(rest, ["<p>#{body}</p>" | acc])
    end
  end

  defp take_fence([], acc), do: {Enum.reverse(acc), []}
  defp take_fence([<<"```", _::binary>> | rest], acc), do: {Enum.reverse(acc), rest}
  defp take_fence([line | rest], acc), do: take_fence(rest, [line | acc])

  defp take_while_prefix(lines, pred, strip, acc) do
    case lines do
      [line | rest] ->
        if pred.(line) do
          take_while_prefix(rest, pred, strip, [strip.(line) | acc])
        else
          {Enum.reverse(acc), lines}
        end

      [] ->
        {Enum.reverse(acc), []}
    end
  end

  defp heading?(line), do: String.match?(line, ~r/^\#{1,6}[ \t]/)
  defp quote?(line), do: String.match?(line, ~r/^\s*>\s?/)
  defp bullet?(line), do: String.match?(line, ~r/^\s*[-*+][ \t]/)
  defp ordered?(line), do: String.match?(line, ~r/^\s*\d{1,3}\.[ \t]/)

  defp paragraph?(line) do
    String.trim(line) != "" and not heading?(line) and not quote?(line) and
      not bullet?(line) and not ordered?(line) and not String.starts_with?(line, "```")
  end

  defp split_heading(line) do
    [hashes, text] = Regex.run(~r/^(\#{1,6})[ \t]+(.*)$/, line, capture: :all_but_first)
    {String.length(hashes), text}
  rescue
    _mismatch -> {1, line}
  end

  defp strip_quote(line), do: String.replace(line, ~r/^\s*>\s?/, "")
  defp strip_bullet(line), do: String.replace(line, ~r/^\s*[-*+][ \t]+/, "")
  defp strip_ordered(line), do: String.replace(line, ~r/^\s*\d{1,3}\.[ \t]+/, "")

  # -- inline spans (operate on already-escaped text) ---------------------

  defp inline(text) do
    text
    |> escape()
    |> replace_code_spans()
    |> replace_links()
    |> replace_emphasis()
  end

  defp escape(text), do: text |> html_escape() |> safe_to_string()

  defp replace_code_spans(html) do
    Regex.replace(~r/`([^`]+)`/, html, ~s(<code class="chat-inline-code">\\1</code>))
  end

  # [label](https://…) — the whole match is already escaped, so the href
  # can only smuggle entities, never break out of the attribute.
  defp replace_links(html) do
    Regex.replace(~r/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/, html, fn _all, label, url ->
      ~s(<a href="#{url}" target="_blank" rel="noopener noreferrer" class="link">#{label}</a>)
    end)
  end

  defp replace_emphasis(html) do
    html
    |> then(&Regex.replace(~r/\*\*([^*]+)\*\*/, &1, "<strong>\\1</strong>"))
    |> then(&Regex.replace(~r/(?<![*\w])\*([^*\n]+)\*(?![*\w])/, &1, "<em>\\1</em>"))
  end
end
