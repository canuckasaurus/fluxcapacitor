defmodule Dify.RAGTest do
  use ExUnit.Case
  doctest Dify.RAG

  test "greets the world" do
    assert Dify.RAG.hello() == :world
  end
end
