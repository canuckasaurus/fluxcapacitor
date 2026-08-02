defmodule Flux.Engine.DocxTest do
  use ExUnit.Case, async: true

  alias Flux.Engine.Docx

  # A minimal in-memory .docx: enough structure for the renderer, no
  # fixture files needed.
  defp docx(body_xml) do
    document = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:body>#{body_xml}</w:body>
    </w:document>
    """

    content_types = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>
    """

    {:ok, {_name, binary}} =
      :zip.create(
        ~c"test.docx",
        [
          {~c"[Content_Types].xml", content_types},
          {~c"word/document.xml", document}
        ],
        [:memory]
      )

    binary
  end

  defp rendered_xml(binary, context) do
    {:ok, out} = Docx.render(binary, context)
    {:ok, entries} = :zip.unzip(out, [:memory])
    {_name, xml} = List.keyfind(entries, ~c"word/document.xml", 0)
    to_string(xml)
  end

  defp p(runs), do: "<w:p>#{runs}</w:p>"
  defp t(text), do: ~s(<w:r><w:t xml:space="preserve">#{text}</w:t></w:r>)

  # What Word would display: the concatenated run text.
  defp visible(xml) do
    ~r{<w:t(?:\s[^>]*)?>([^<]*)</w:t>}
    |> Regex.scan(xml)
    |> Enum.map_join(fn [_whole, inner] -> inner end)
  end

  test "renders whole tags and XML-escapes interpolated values" do
    binary = docx(p(t("Dear {{ client.name }} &amp; co,")))
    xml = rendered_xml(binary, %{"client" => %{"name" => "Smith <Jones>"}})

    assert xml =~ "Dear Smith &lt;Jones&gt; &amp; co,"
  end

  test "repairs tags Word split across runs, preserving other runs" do
    body = p(t("Intact prefix. ") <> t("Total: {") <> t("{ amou") <> t("nt }} due"))
    xml = rendered_xml(docx(body), %{"amount" => 125})

    assert xml =~ "Intact prefix. "
    assert visible(xml) =~ "Total: 125 due"
  end

  test "paragraph tags include, exclude, and repeat whole paragraphs" do
    body =
      p(t("{%p if senior %}")) <>
        p(t("Senior clause applies.")) <>
        p(t("{%p endif %}")) <>
        p(t("{%p for item in items %}")) <>
        p(t("- {{ item }}")) <>
        p(t("{%p endfor %}"))

    xml = rendered_xml(docx(body), %{"senior" => true, "items" => ["a", "b"]})
    assert xml =~ "Senior clause applies."
    assert xml =~ "- a"
    assert xml =~ "- b"
    refute xml =~ "{%"

    xml = rendered_xml(docx(body), %{"senior" => false, "items" => []})
    refute xml =~ "Senior clause"
  end

  test "table row tags repeat rows" do
    body =
      "<w:tbl><w:tr><w:tc>#{p(t("{%tr for line in lines %}"))}</w:tc></w:tr>" <>
        "<w:tr><w:tc>#{p(t("{{ line.desc }}: {{ line.qty }}"))}</w:tc></w:tr>" <>
        "<w:tr><w:tc>#{p(t("{%tr endfor %}"))}</w:tc></w:tr></w:tbl>"

    lines = [%{"desc" => "Widget", "qty" => 3}, %{"desc" => "Gadget", "qty" => 1}]
    xml = rendered_xml(docx(body), %{"lines" => lines})

    assert xml =~ "Widget: 3"
    assert xml =~ "Gadget: 1"
    refute xml =~ "{%"
  end

  test "Word's curly quotes inside tags are straightened" do
    body = p(t("{{ missing | default(“n/a”) }}"))
    xml = rendered_xml(docx(body), %{})

    assert xml =~ "n/a"
  end

  test "newlines in values become Word line breaks" do
    xml = rendered_xml(docx(p(t("{{ address }}"))), %{"address" => "1 Main St\nSpringfield"})

    assert xml =~ "1 Main St</w:t><w:br/><w:t"
    assert xml =~ "Springfield"
  end

  test "extract_tags lists root variables, excluding loop locals" do
    body =
      p(t("{{ client.name | upper }} owes {{ amount }}")) <>
        p(t("{%p for item in items %}")) <>
        p(t("{{ item }} {{ loop.index }}")) <>
        p(t("{%p endfor %}")) <>
        p(t("{% if urgent %}now{% endif %}"))

    assert {:ok, tags} = Docx.extract_tags(docx(body))
    assert tags == ["amount", "client", "items", "urgent"]
  end

  test "malformed Jinja fails loudly at extraction and render" do
    binary = docx(p(t("{% if x %}never closed")))

    assert {:error, message} = Docx.extract_tags(binary)
    assert message =~ "endif"

    assert {:error, message} = Docx.render(binary, %{"x" => true})
    assert message =~ "endif"
  end

  test "non-docx input errors cleanly" do
    assert {:error, message} = Docx.render(<<"not a zip">>, %{})
    assert message =~ ".docx"

    {:ok, {_name, zip}} = :zip.create(~c"z.zip", [{~c"a.txt", "hi"}], [:memory])
    assert {:error, message} = Docx.render(zip, %{})
    assert message =~ "word/document.xml"
  end
end
