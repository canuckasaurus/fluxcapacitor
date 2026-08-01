defmodule Flux.Engine.LintTest do
  use ExUnit.Case, async: true

  alias Flux.Engine.Lint

  defp graph(template) do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "start", "config" => %{"variables" => []}},
        %{"id" => "llm_1", "type" => "llm", "config" => %{"prompt" => "{{start.query}}"}},
        %{"id" => "answer_1", "type" => "answer", "config" => %{"answer" => template}},
        %{"id" => "orphan", "type" => "template", "config" => %{"template" => "alone"}}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "llm_1", "source_handle" => "default"},
        %{"id" => "e2", "source" => "llm_1", "target" => "answer_1", "source_handle" => "default"}
      ]
    }
  end

  test "valid upstream and namespace references produce no warnings" do
    assert Lint.reference_warnings(graph("{{llm_1.text}} {{sys.query}} {{env.KEY}}")) == []
  end

  test "unknown nodes and non-upstream references warn" do
    warnings = Lint.reference_warnings(graph("{{ghost.text}} {{orphan.output}}"))

    assert Enum.any?(warnings, &(&1 =~ ~s(no node "ghost" exists)))
    assert Enum.any?(warnings, &(&1 =~ ~s("orphan" is not upstream)))
  end

  test "self references and nested config strings are handled" do
    graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "start", "config" => %{"variables" => []}},
        %{
          "id" => "loop_1",
          "type" => "loop",
          "config" => %{
            "conditions" => [%{"left" => "{{loop_1.score}}", "right" => "{{nope.x}}"}]
          }
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "loop_1", "source_handle" => "default"}
      ]
    }

    warnings = Lint.reference_warnings(graph)
    refute Enum.any?(warnings, &(&1 =~ "loop_1.…"))
    assert Enum.any?(warnings, &(&1 =~ ~s(no node "nope" exists)))
  end
end
