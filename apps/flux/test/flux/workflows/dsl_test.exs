defmodule Flux.Workflows.DSLTest do
  @moduledoc """
  Golden-harness seed: imports real portable DSL exports (copied verbatim from
  dify/api/tests/fixtures/workflow) and checks structural validity plus run
  behavior for the node types we support. Recorded run traces from a live
  the reference platform instance extend this suite later.
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

    # Reference semantics per the fixture description: query containing "hello"
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

  test "export emits portable DSL that round-trips" do
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

  # Binds stub models on every LLM-backed node type (llm/classifier/extractor).
  defp bind_all_stub_models(graph) do
    update_in(graph, ["nodes"], fn nodes ->
      Enum.map(nodes, fn
        %{"type" => type} = node
        when type in ["llm", "question_classifier", "parameter_extractor"] ->
          node
          |> put_in(["config", "provider_plugin_id"], "stub")
          |> put_in(["config", "model"], "stub-1")

        node ->
          node
      end)
    end)
  end

  test "classifier_routing: classifier branches route and the aggregator joins" do
    assert {:ok, parsed} = DSL.parse(fixture!("classifier_routing_with_aggregator_workflow.yml"))
    assert parsed.warnings == []

    classifier = Enum.find(parsed.graph["nodes"], &(&1["type"] == "question_classifier"))
    assert [%{"id" => "billing"}, %{"id" => "support"}] = classifier["config"]["classes"]

    # Class-id edge handles survived the import.
    handles = parsed.graph["edges"] |> Enum.map(& &1["source_handle"]) |> Enum.sort()
    assert "billing" in handles and "support" in handles

    aggregator = Enum.find(parsed.graph["nodes"], &(&1["type"] == "variable_aggregator"))
    assert length(aggregator["config"]["variables"]) == 2

    assert {:ok, graph} = parsed.graph |> bind_all_stub_models() |> Engine.build()

    host = %Host{
      emit: fn _event -> :ok end,
      invoke_llm: fn request, chunk_emit ->
        cond do
          Enum.any?(Map.get(request, :tools, []), &(&1["name"] == "classify")) ->
            [_system, %{content: query}] = request.messages
            class = if query =~ "invoice", do: "billing", else: "support"

            {:ok,
             %{
               content: "",
               usage: %{},
               tool_calls: [%{id: "c1", name: "classify", arguments: %{"class_id" => class}}]
             }}

          true ->
            [%{content: system} | _rest] = request.messages
            reply = if system =~ "billing", do: "BILLING-ANSWER", else: "SUPPORT-ANSWER"
            chunk_emit.(reply)
            {:ok, %{content: reply, usage: %{}, tool_calls: []}}
        end
      end
    }

    assert {:ok, result} = Engine.run(graph, %{"query" => "where is my invoice?"}, host)
    assert result.outputs["answer"] == "BILLING-ANSWER"

    assert {:ok, result} = Engine.run(graph, %{"query" => "the app crashes"}, host)
    assert result.outputs["answer"] == "SUPPORT-ANSWER"
  end

  test "extractor_list_ops: extractor + list-operator + env import and run" do
    assert {:ok, parsed} = DSL.parse(fixture!("extractor_with_list_operator_workflow.yml"))
    assert parsed.warnings == []

    # environment_variables became graph env.
    assert parsed.graph["env"] == %{"REGION" => "eu-west"}

    extractor = Enum.find(parsed.graph["nodes"], &(&1["type"] == "parameter_extractor"))

    assert [%{"name" => "city", "required" => true}, %{"name" => "days", "type" => "number"}] =
             extractor["config"]["parameters"]

    list_operator = Enum.find(parsed.graph["nodes"], &(&1["type"] == "list_operator"))
    assert list_operator["config"]["filter"] == %{"operator" => "contains", "value" => "a"}
    assert list_operator["config"]["sort"] == "asc"
    assert list_operator["config"]["limit"] == 2

    assert {:ok, graph} = parsed.graph |> bind_all_stub_models() |> Engine.build()

    host = %Host{
      emit: fn _event -> :ok end,
      invoke_llm: fn _request, _chunk ->
        {:ok,
         %{
           content: "",
           usage: %{},
           tool_calls: [
             %{id: "e1", name: "extract", arguments: %{"city" => "Lisbon", "days" => 4}}
           ]
         }}
      end
    }

    inputs = %{
      "query" => "4 days in Lisbon",
      "items" => ~s(["banana", "cherry", "apple", "avocado"])
    }

    assert {:ok, result} = Engine.run(graph, inputs, host)
    assert result.outputs["city"] == "Lisbon"
    # End-node templates render values to text, so the list arrives as JSON.
    assert result.outputs["picked"] == ~s(["apple","avocado"])
    assert result.outputs["region"] == "eu-west"
  end

  test "rag_chatflow: knowledge-retrieval chatflow imports and runs with sys vars" do
    assert {:ok, parsed} = DSL.parse(fixture!("rag_chatflow_with_knowledge.yml"))
    assert parsed.mode == "advanced-chat"
    # The importer flags that dataset ids never transfer.
    assert Enum.any?(parsed.warnings, &(&1 =~ "rebind its dataset"))

    # Conversation variables imported into the graph.
    assert [%{"name" => "last_topic"}] = parsed.graph["conversation_variables"]

    kb = Enum.find(parsed.graph["nodes"], &(&1["type"] == "knowledge_retrieval"))
    assert kb["config"]["query"] == "{{sys.query}}"
    assert kb["config"]["top_k"] == 3
    assert kb["config"]["dataset_id"] == ""

    # Rebind the dataset (as the warning instructs) and run behaviorally.
    graph =
      parsed.graph
      |> update_in(["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"type" => "knowledge_retrieval"} = node ->
            put_in(node, ["config", "dataset_id"], "ds-local")

          %{"type" => "llm"} = node ->
            node
            |> put_in(["config", "provider_plugin_id"], "stub")
            |> put_in(["config", "model"], "stub-1")

          node ->
            node
        end)
      end)

    assert {:ok, built} = Engine.build(graph)

    host = %Host{
      emit: fn _event -> :ok end,
      retrieve_knowledge: fn %{dataset_id: "ds-local", query: "refund window?"} ->
        {:ok, [%{content: "Refunds within 30 days.", document_name: "policy.md", score: 0.9}]}
      end,
      invoke_llm: fn request, chunk_emit ->
        [_system, %{content: user}] = request.messages
        assert user =~ "Refunds within 30 days."
        assert user =~ "refund window?"
        chunk_emit.("Within 30 days.")
        {:ok, %{content: "Within 30 days.", usage: %{}, tool_calls: []}}
      end
    }

    assert {:ok, result} =
             Engine.run(built, %{}, host, sys: %{"query" => "refund window?"})

    assert result.outputs["answer"] == "Within 30 days."
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
