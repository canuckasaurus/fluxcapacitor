defmodule Flux.Workflows.TemplatesTest do
  use ExUnit.Case, async: true

  alias Flux.Workflows.Templates

  test "every template's graph builds cleanly" do
    templates = Templates.all()
    assert length(templates) == 6

    for %{id: id} <- templates do
      template = Templates.get(id)
      assert {:ok, _graph} = Flux.Engine.build(template.graph)
      assert Enum.all?(template.graph["nodes"], &match?(%{"position" => %{}}, &1))
    end
  end

  test "unknown template ids are nil" do
    assert Templates.get("flux-capacitor-schematic") == nil
  end
end
