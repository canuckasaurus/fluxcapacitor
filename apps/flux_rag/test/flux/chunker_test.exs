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
end
