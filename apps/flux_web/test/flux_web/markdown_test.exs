defmodule FluxWeb.MarkdownTest do
  use ExUnit.Case, async: true

  defp render(text) do
    {:safe, html} = FluxWeb.Markdown.render(text)
    html
  end

  test "blocks: headings, lists, quotes, fences, rules, paragraphs" do
    html =
      render("""
      ## Plan
      Take these steps:
      1. Charge to 1.21 gigawatts
      2. Hit 88 mph
      - flux capacitor
      - stainless body
      > Roads? Where we're going, we don't need roads.
      ---
      ```elixir
      IO.puts("hi")
      ```
      """)

    assert html =~ "<h2>Plan</h2>"
    assert html =~ "<ol><li>Charge to 1.21 gigawatts</li><li>Hit 88 mph</li></ol>"
    assert html =~ "<ul><li>flux capacitor</li><li>stainless body</li></ul>"
    assert html =~ "<blockquote>Roads? Where we"
    assert html =~ "<hr/>"
    assert html =~ ~s|<code class="language-elixir">IO.puts(&quot;hi&quot;)</code>|
  end

  test "inline spans: code, bold, italic, safe links" do
    html =
      render("Use `mix test` — it is **fast** and *thorough*. See [docs](https://example.com/a).")

    assert html =~ ~s(<code class="chat-inline-code">mix test</code>)
    assert html =~ "<strong>fast</strong>"
    assert html =~ "<em>thorough</em>"
    assert html =~ ~s(<a href="https://example.com/a" target="_blank" rel="noopener noreferrer")
  end

  test "raw HTML and script payloads are escaped, never rendered" do
    html = render("<script>alert(1)</script> and <img src=x onerror=alert(2)>")

    refute html =~ "<script>"
    refute html =~ "<img"
    assert html =~ "&lt;script&gt;"

    # javascript: links never become anchors.
    refute render("[click](javascript:alert(1))") =~ "<a "

    # Attribute breakout via a quote in the URL stays inside the escaped href.
    breakout = render(~s{[x](https://e.com/"onmouseover="alert(1))})
    refute breakout =~ ~s(" onmouseover=)

    # Code fences don't smuggle markup either.
    assert render("```\n<script>alert(3)</script>\n```") =~ "&lt;script&gt;"
  end

  test "non-binary input renders empty" do
    assert FluxWeb.Markdown.render(nil) == {:safe, ""}
    assert FluxWeb.Markdown.render(%{}) == {:safe, ""}
  end
end
