defmodule Flux.RAG.EntitiesTest do
  use ExUnit.Case, async: true

  alias Flux.RAG.Entities

  test "extracts multiword names, acronyms, and notable single words" do
    text = """
    The Flux Capacitor was invented by Emmett Brown. NASA later reviewed
    the design in Houston. It is not clear when this happened.
    """

    names = Entities.extract(text)

    assert "flux capacitor" in names
    assert "emmett brown" in names
    assert "nasa" in names
    assert "houston" in names

    # Sentence furniture never becomes an entity.
    refute "the" in names
    refute "it" in names
  end

  test "normalizes case and whitespace, dedupes, and caps output" do
    assert Entities.normalize("  Acme   Corp ") == "acme corp"

    names = Entities.extract("Acme Corp partnered with ACME CORP and Acme Corp again.")
    assert Enum.count(names, &(&1 == "acme corp")) == 1

    many = Enum.map_join(1..80, ". ", fn n -> "Company#{n} Incorporated" end)
    assert length(Entities.extract(many)) <= 50
  end

  test "handles empty and non-string input" do
    assert Entities.extract("") == []
    assert Entities.extract("no capitals anywhere here") == []
    assert Entities.extract(nil) == []
  end
end
