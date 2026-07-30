defmodule Flux.Workflows.DSLTest do
  @moduledoc """
  Golden-harness seed: imports real Dify DSL exports (copied verbatim from
  dify/api/tests/fixtures/workflow) and checks structural validity plus run
  behavior for the node types we support. Recorded run traces from a live
  Dify instance extend this suite later.
  """
  use ExUnit.Case, async: true

  alias Flux.Engine
  alias Flux.Engine.Host
  alias Flux.Workflows.DSL

  @fixtures Path.expand("../../support/fixtures/dsl", __DIR__)

  defp fixture!(name), do: File.read!(Path.join(@fixtures, name))

  # Real exports carry workspace-specific model bindings (often empty in
  # fixtures); the harness substitutes a stub binding — flow semantics are
  # what's under test, not the provider.
  defp bind_stub_models(graph) do
    update_in(graph, ["nodes"], fn nodes ->
      Enum.map(nodes, fn
        %{"type" => "llm"} = node ->
          node
          |> put_in(["config", "provider_plugin_id"], "stub")
          |> put_in(["config", "model"], "stub-1")

        node ->
          node
      end)
    end)
  end

  defp stub_host(reply \\ "LLM-REPLY") do
    %Host{
      emit: fn _event -> :ok end,
      invoke_llm: fn _request, chunk_emit ->
        chunk_emit.(reply)
        {:ok, %{content: reply, usage: %{"input_tokens" => 1, "output_tokens" => 1}}}
      end
    }
  end

  test "basic_chatflow: start → llm → answer imports and runs" do
    assert {:ok, parsed} = DSL.parse(fixture!("basic_chatflow.yml"))
    assert parsed.name == "basic_chatflow"
    assert parsed.mode == "advanced-chat"
    assert parsed.warnings == []

    types = Enum.map(parsed.graph["nodes"], & &1["type"])
    assert Enum.sort(types) == ["answer", "llm", "start"]

    assert {:ok, graph} = parsed.graph |> bind_stub_models() |> Engine.build()
    assert {:ok, result} = Engine.run(graph, %{}, stub_host())
    assert result.outputs["answer"] =~ "LLM-REPLY"
  end

  test "conditional_hello_branching: if-else routes to the right end node" do
    assert {:ok, parsed} = DSL.parse(fixture!("conditional_hello_branching_workflow.yml"))
    assert parsed.warnings == []

    if_else = Enum.find(parsed.graph["nodes"], &(&1["type"] == "if_else"))
    assert [condition] = if_else["config"]["conditions"]
    assert condition["operator"] == "contains"
    assert condition["right"] == "hello"
    # Selector [start_id, query] became a template reference.
    assert condition["left"] =~ ~r/^\{\{\d+\.query\}\}$/

    handles = parsed.graph["edges"] |> Enum.map(& &1["source_handle"]) |> Enum.sort()
    assert handles == ["default", "false", "true"]

    assert {:ok, graph} = Engine.build(parsed.graph)

    # Dify semantics per the fixture description: query containing "hello"
    # exits via the {"true": query} end node, otherwise {"false": query}.
    assert {:ok, result} = Engine.run(graph, %{"query" => "well hello there"}, stub_host())
    assert result.outputs == %{"true" => "well hello there"}

    assert {:ok, result} = Engine.run(graph, %{"query" => "goodbye"}, stub_host())
    assert result.outputs == %{"false" => "goodbye"}
  end

  test "conditional_streaming_vs_template: template-transform Jinja args convert" do
    assert {:ok, parsed} =
             DSL.parse(fixture!("conditional_streaming_vs_template_workflow.yml"))

    template = Enum.find(parsed.graph["nodes"], &(&1["type"] == "template"))
    assert template != nil
    # Jinja {{ arg }} references were rewritten to {{node.field}} selectors.
    assert template["config"]["template"] =~ ~r/\{\{[\w-]+\.[\w-]+\}\}/

    assert {:ok, _graph} = Engine.build(parsed.graph)
  end

  test "http_request fixture: http-request imports, tool still drops with warning" do
    assert {:ok, parsed} = DSL.parse(fixture!("http_request_with_json_tool_workflow.yml"))

    refute Enum.any?(parsed.warnings, &(&1 =~ "http-request"))
    assert Enum.any?(parsed.graph["nodes"], &(&1["type"] == "http_request"))
    assert Enum.any?(parsed.warnings, &(&1 =~ "\"tool\"" or &1 =~ "type \"tool\""))

    kept = MapSet.new(parsed.graph["nodes"], & &1["id"])

    for edge <- parsed.graph["edges"] do
      assert MapSet.member?(kept, edge["source"])
      assert MapSet.member?(kept, edge["target"])
    end
  end

  test "export emits Dify-importable DSL that round-trips" do
    {:ok, parsed} = DSL.parse(fixture!("conditional_hello_branching_workflow.yml"))
    workflow = %{name: "roundtrip", description: "d", graph: parsed.graph}

    exported = DSL.export(workflow)
    assert {:ok, reparsed} = DSL.parse(exported)
    assert reparsed.warnings == []

    types = fn graph -> graph["nodes"] |> Enum.map(&{&1["id"], &1["type"]}) |> Enum.sort() end
    assert types.(reparsed.graph) == types.(parsed.graph)

    assert {:ok, _built} = Engine.build(reparsed.graph)

    if_else = Enum.find(reparsed.graph["nodes"], &(&1["type"] == "if_else"))
    assert [%{"operator" => "contains", "right" => "hello"}] = if_else["config"]["conditions"]
  end

  test "rejects non-DSL and unsupported app modes" do
    assert {:error, message} = DSL.parse("just: yaml")
    assert message =~ "Missing app section"

    chat_dsl = """
    app:
      name: chat app
      mode: chat
    kind: app
    """

    assert {:error, message} = DSL.parse(chat_dsl)
    assert message =~ "Only workflow and advanced-chat"

    assert {:error, _message} = DSL.parse(": broken [yaml")
  end
end
