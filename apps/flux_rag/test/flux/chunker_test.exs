defmodule Flux.RAG.ChunkerTest do
  use ExUnit.Case, async: true

  alias Flux.RAG.Chunker

  test "short text stays one chunk" do
    assert ["hello world"] = Chunker.split("hello world")
  end

  test "long text splits into overlapping chunks under the size cap" do
    paragraphs = Enum.map_join(1..12, "\n\n", fn n -> String.duplicate("word#{n} ", 40) end)
    chunks = Chunker.split(paragraphs)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= 1_200))
    assert Enum.at(chunks, 1) =~ "…"
  end

  test "oversized text hard-wraps rather than exceeding the cap" do
    monster = String.duplicate("a", 3_000)
    chunks = Chunker.split(monster, max_chars: 500, overlap: 0)
    assert Enum.all?(chunks, &(String.length(&1) <= 500))
    assert Enum.join(chunks) == monster
  end

  test "markdown mode splits at headings and prefixes each chunk with its heading" do
    text = """
    Intro paragraph before any heading.

    # Refunds

    #{String.duplicate("Refund policy detail sentence. ", 30)}

    ## Shipping

    Standard shipping takes days.
    """

    chunks = Chunker.split(text, markdown: true, max_chars: 400, overlap: 0)

    assert Enum.at(chunks, 0) =~ "Intro paragraph"
    refute Enum.at(chunks, 0) =~ "#"

    refund_chunks = Enum.filter(chunks, &String.starts_with?(&1, "# Refunds"))
    assert length(refund_chunks) > 1
    assert Enum.all?(refund_chunks, &(&1 =~ "Refund policy detail"))

    assert Enum.any?(chunks, &String.starts_with?(&1, "## Shipping"))
  end

  test "markdown mode without headings behaves like plain splitting" do
    assert Chunker.split("no headings here", markdown: true) == ["no headings here"]
  end

  test "parent-child returns child chunks paired with their parent section" do
    sentences = for index <- 1..40, do: "Sentence number #{index} carries some payload."
    text = Enum.join(sentences, " ")

    pairs = Chunker.split_parent_child(text, max_chars: 800)

    assert length(pairs) > 1

    for {child, parent} <- pairs do
      assert String.length(child) <= 800
      assert String.contains?(parent, String.trim_leading(child, "…"))
      assert String.length(parent) >= String.length(child)
    end

    # Several children share one parent — that's the point.
    parents = pairs |> Enum.map(fn {_child, parent} -> parent end) |> Enum.uniq()
    assert length(parents) < length(pairs)
  end

  test "parent-child on tiny text yields the text as both child and parent" do
    assert [{"just a note", "just a note"}] = Chunker.split_parent_child("just a note")
  end
end
