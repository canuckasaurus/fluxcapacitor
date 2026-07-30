defmodule Flux.EngineTest do
  use ExUnit.Case, async: true

  alias Flux.Engine
  alias Flux.Engine.Host

  defp node!(id, type, config \\ %{}) do
    %{"id" => id, "type" => type, "title" => id, "config" => config}
  end

  defp edge!(source, target, handle \\ "default") do
    %{
      "id" => "e-#{source}-#{handle}-#{target}",
      "source" => source,
      "target" => target,
      "source_handle" => handle
    }
  end

  defp start_node(variables \\ [%{"name" => "query", "type" => "text", "required" => true}]) do
    node!("start", "start", %{"variables" => variables})
  end

  defp echo_host(test_pid \\ nil) do
    %Host{
      emit: fn event -> if test_pid, do: send(test_pid, {:event, event}) end,
      invoke_llm: fn request, chunk_emit ->
        [%{content: prompt} | _rest] = Enum.reverse(request.messages)

        for word <- String.split("echo: " <> prompt, " ") do
          chunk_emit.(word <> " ")
        end

        {:ok, %{content: "echo: " <> prompt, usage: %{"input_tokens" => 1, "output_tokens" => 2}}}
      end
    }
  end

  describe "build/1 validation" do
    test "accepts a minimal valid graph" do
      graph = %{
        "nodes" => [start_node(), node!("a", "answer", %{"answer" => "hi"})],
        "edges" => [edge!("start", "a")]
      }

      assert {:ok, built} = Engine.build(graph)
      assert built.start_id == "start"
    end

    test "rejects a graph without a start node" do
      assert {:error, errors} = Engine.build(%{"nodes" => [node!("a", "answer")], "edges" => []})
      assert Enum.any?(errors, &(&1 =~ "needs a start node"))
    end

    test "rejects duplicate ids, unknown types, and dangling edges" do
      graph = %{
        "nodes" => [start_node(), node!("a", "mystery"), node!("a", "answer")],
        "edges" => [edge!("start", "ghost")]
      }

      assert {:error, errors} = Engine.build(graph)
      assert Enum.any?(errors, &(&1 =~ "duplicate node id a"))
      assert Enum.any?(errors, &(&1 =~ "unknown type mystery"))
      assert Enum.any?(errors, &(&1 =~ "unknown node ghost"))
    end

    test "rejects cycles" do
      graph = %{
        "nodes" => [start_node(), node!("a", "template"), node!("b", "template")],
        "edges" => [edge!("start", "a"), edge!("a", "b"), edge!("b", "a")]
      }

      assert {:error, errors} = Engine.build(graph)
      assert Enum.any?(errors, &(&1 =~ "cycle"))
    end

    test "rejects two edges leaving the same handle, and bad if_else handles" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("cond", "if_else"),
          node!("a", "answer"),
          node!("b", "answer")
        ],
        "edges" => [
          edge!("start", "cond"),
          edge!("cond", "a", "true"),
          edge!("cond", "b", "maybe")
        ]
      }

      assert {:error, errors} = Engine.build(graph)
      assert Enum.any?(errors, &(&1 =~ "handle maybe"))

      graph = %{
        "nodes" => [start_node(), node!("a", "answer"), node!("b", "answer")],
        "edges" => [edge!("start", "a"), %{"id" => "dup", "source" => "start", "target" => "b"}]
      }

      assert {:error, errors} = Engine.build(graph)
      assert Enum.any?(errors, &(&1 =~ "2 edges on handle default"))
    end
  end

  describe "run/3" do
    test "runs start → llm → answer with streaming and usage" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("llm_1", "llm", %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "prompt" => "{{start.query}}"
          }),
          node!("answer_1", "answer", %{"answer" => "A: {{llm_1.text}}"})
        ],
        "edges" => [edge!("start", "llm_1"), edge!("llm_1", "answer_1")]
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "hello"}, echo_host(self()))

      assert result.outputs == %{"answer" => "A: echo: hello"}
      assert [start_exec, llm_exec, answer_exec] = result.node_executions
      assert start_exec["node_id"] == "start"
      assert llm_exec["outputs"]["usage"]["output_tokens"] == 2
      assert answer_exec["status"] == "succeeded"

      assert_received {:event, {:workflow_started, _inputs}}
      assert_received {:event, {:node_started, %{node_id: "start"}}}
      assert_received {:event, {:node_chunk, %{node_id: "llm_1", delta: "echo: "}}}
      assert_received {:event, {:node_finished, %{node_id: "answer_1"}}}
    end

    test "start node enforces required inputs and coerces numbers" do
      graph = %{
        "nodes" => [
          start_node([
            %{"name" => "query", "type" => "text", "required" => true},
            %{"name" => "count", "type" => "number"}
          ]),
          node!("t", "template", %{"template" => "{{start.query}}/{{start.count}}"})
        ],
        "edges" => [edge!("start", "t")]
      }

      {:ok, built} = Engine.build(graph)

      assert {:error, failure} = Engine.run(built, %{}, echo_host())
      assert failure.error =~ "query is required"
      assert failure.node_id == "start"

      assert {:ok, result} = Engine.run(built, %{"query" => "q", "count" => "42"}, echo_host())
      assert result.outputs == %{"output" => "q/42"}
    end

    test "if_else branches on the rendered condition" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("cond", "if_else", %{
            "logical_operator" => "and",
            "conditions" => [
              %{"left" => "{{start.query}}", "operator" => "contains", "right" => "bug"}
            ]
          }),
          node!("yes", "answer", %{"answer" => "it's a bug"}),
          node!("no", "answer", %{"answer" => "not a bug"})
        ],
        "edges" => [
          edge!("start", "cond"),
          edge!("cond", "yes", "true"),
          edge!("cond", "no", "false")
        ]
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, %{outputs: %{"answer" => "it's a bug"}}} =
               Engine.run(built, %{"query" => "found a bug"}, echo_host())

      assert {:ok, %{outputs: %{"answer" => "not a bug"}}} =
               Engine.run(built, %{"query" => "all fine"}, echo_host())
    end

    test "end node collects mapped outputs" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("t", "template", %{"template" => "hi {{start.query}}"}),
          node!("done", "end", %{
            "outputs" => [%{"key" => "greeting", "value" => "{{t.output}}"}]
          })
        ],
        "edges" => [edge!("start", "t"), edge!("t", "done")]
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, %{outputs: %{"greeting" => "hi world"}}} =
               Engine.run(built, %{"query" => "world"}, echo_host())
    end

    test "a failing node stops the run with node_failed" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("llm_1", "llm", %{"provider_plugin_id" => "", "model" => ""})
        ],
        "edges" => [edge!("start", "llm_1")]
      }

      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "x"}, echo_host(self()))
      assert failure.node_id == "llm_1"
      assert failure.error =~ "needs a provider and model"
      assert Enum.any?(failure.node_executions, &(&1["status"] == "failed"))
      assert_received {:event, {:node_failed, %{node_id: "llm_1"}}}
    end

    test "tool node renders args and calls the host" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("tool_1", "tool", %{
            "toolset_id" => "ts-1",
            "operation_id" => "listPets",
            "args" => %{"limit" => "3", "q" => "{{start.query}}"}
          }),
          node!("answer_1", "answer", %{"answer" => "{{tool_1.text}} ({{tool_1.status}})"})
        ],
        "edges" => [edge!("start", "tool_1"), edge!("tool_1", "answer_1")]
      }

      host = %Host{
        emit: fn _event -> :ok end,
        invoke_tool: fn %{toolset_id: "ts-1", operation_id: "listPets", args: args} ->
          assert args == %{"limit" => "3", "q" => "cats"}
          {:ok, %{status: 200, body: %{"ok" => true}, text: "pets!"}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "cats"}, host)
      assert result.outputs == %{"answer" => "pets! (200)"}
    end

    test "tool node without a host capability fails cleanly" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("tool_1", "tool", %{"toolset_id" => "x", "operation_id" => "y"})
        ],
        "edges" => [edge!("start", "tool_1")]
      }

      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "x"}, echo_host())
      assert failure.error =~ "cannot call tools"
    end

    test "http_request node renders templates and calls the host" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("http_1", "http_request", %{
            "method" => "post",
            "url" => "https://api.example.com/{{start.query}}",
            "headers" => [%{"key" => "X-T", "value" => "{{start.query}}"}],
            "body" => "q={{start.query}}"
          }),
          node!("end_1", "end", %{
            "outputs" => [%{"key" => "code", "value" => "{{http_1.status_code}}"}]
          })
        ],
        "edges" => [edge!("start", "http_1"), edge!("http_1", "end_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        http_request: fn spec ->
          assert spec.method == "post"
          assert spec.url == "https://api.example.com/abc"
          assert spec.headers == [{"X-T", "abc"}]
          assert spec.body == "q=abc"
          {:ok, %{status: 201, body: %{"ok" => true}, text: "created"}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, %{outputs: %{"code" => "201"}}} = Engine.run(built, %{"query" => "abc"}, host)
    end

    test "unresolved template references render blank" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("t", "template", %{"template" => "[{{nope.missing}}]"})
        ],
        "edges" => [edge!("start", "t")]
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, %{outputs: %{"output" => "[]"}}} =
               Engine.run(built, %{"query" => "x"}, echo_host())
    end
  end
end
