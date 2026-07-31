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

    test "code node renders inputs and maps result + stdout to outputs" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("code_1", "code", %{
            "language" => "python3",
            "code" => "def main(q): return {}",
            "inputs" => [%{"name" => "q", "value" => "{{start.query}}"}]
          }),
          node!("end_1", "end", %{
            "outputs" => [%{"key" => "up", "value" => "{{code_1.upper}}"}]
          })
        ],
        "edges" => [edge!("start", "code_1"), edge!("code_1", "end_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        run_code: fn spec ->
          assert spec.language == "python3"
          assert spec.inputs == %{"q" => "abc"}
          {:ok, %{result: %{"upper" => String.upcase(spec.inputs["q"])}, stdout: "traced"}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, %{outputs: %{"up" => "ABC"}}} = Engine.run(built, %{"query" => "abc"}, host)
    end

    test "code node without host capability or non-dict result fails" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("code_1", "code", %{"code" => "def main(): return 1"})
        ],
        "edges" => [edge!("start", "code_1")]
      }

      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "x"}, echo_host())
      assert failure.error =~ "cannot execute code"

      bad_host = %Host{emit: fn _e -> :ok end, run_code: fn _s -> {:ok, %{result: 42}} end}
      assert {:error, failure} = Engine.run(built, %{"query" => "x"}, bad_host)
      assert failure.error =~ "must return a dict"
    end

    test "agent node loops through tool calls then answers, capped by max_iterations" do
      tools = [
        %{
          "name" => "get_weather",
          "description" => "d",
          "parameters" => %{"type" => "object"},
          "toolset_id" => "ts1",
          "operation_id" => "getWeather"
        }
      ]

      graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "max_iterations" => 3,
            "tools" => tools
          })
        ],
        "edges" => [edge!("start", "agent_1")]
      }

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          turn = Elixir.Agent.get_and_update(counter, &{&1, &1 + 1})

          if turn == 0 do
            assert [%{"name" => "get_weather"}] = request.tools

            {:ok,
             %{
               content: "",
               usage: %{},
               tool_calls: [%{id: "c1", name: "get_weather", arguments: %{"city" => "Paris"}}]
             }}
          else
            # Second turn sees the tool result in history.
            assert Enum.any?(request.messages, &(&1[:role] == :tool and &1.content =~ "sunny"))
            {:ok, %{content: "It is sunny in Paris.", usage: %{}, tool_calls: []}}
          end
        end,
        invoke_tool: fn %{toolset_id: "ts1", operation_id: "getWeather", args: args} ->
          assert args == %{"city" => "Paris"}
          {:ok, %{status: 200, body: %{}, text: "sunny, 22C"}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "weather in paris"}, host)
      assert result.outputs["text"] == "It is sunny in Paris."
      assert result.outputs["iterations"] == 2
      assert result.outputs["tool_calls"] == 1
    end

    test "agent node errors past max_iterations" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "max_iterations" => 2,
            "tools" => [
              %{"name" => "t", "parameters" => %{}, "toolset_id" => "x", "operation_id" => "y"}
            ]
          })
        ],
        "edges" => [edge!("start", "agent_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn _request, _chunk ->
          {:ok, %{content: "", usage: %{}, tool_calls: [%{id: "c", name: "t", arguments: %{}}]}}
        end,
        invoke_tool: fn _spec -> {:ok, %{status: 200, body: %{}, text: "r"}} end
      }

      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "q"}, host)
      assert failure.error =~ "max_iterations (2)"
    end

    test "agent node with output_schema terminates via final_output" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "max_iterations" => 3,
            "output_schema" => %{
              "type" => "object",
              "properties" => %{"answer" => %{"type" => "string"}}
            },
            "tools" => []
          })
        ],
        "edges" => [edge!("start", "agent_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          # The synthetic final_output tool is offered alongside real tools.
          assert Enum.any?(request.tools, &(&1["name"] == "final_output"))

          {:ok,
           %{
             content: "",
             usage: %{},
             tool_calls: [
               %{id: "f1", name: "final_output", arguments: %{"answer" => "42"}}
             ]
           }}
        end,
        invoke_tool: fn _spec -> {:ok, %{status: 200, body: %{}, text: ""}} end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "meaning of life"}, host)
      assert result.outputs["status"] == "completed"
      assert result.outputs["output"] == %{"answer" => "42"}
      assert result.outputs["iterations"] == 1
    end

    test "agent node defers on a deferred tool and resumes from the snapshot" do
      tools = [
        %{
          "name" => "ask_human",
          "description" => "ask the operator",
          "parameters" => %{"type" => "object"},
          "toolset_id" => "ts1",
          "operation_id" => "ask",
          "deferred" => true
        }
      ]

      graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "max_iterations" => 5,
            "tools" => tools
          })
        ],
        "edges" => [edge!("start", "agent_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn _request, _chunk ->
          {:ok,
           %{
             content: "",
             usage: %{},
             tool_calls: [%{id: "d1", name: "ask_human", arguments: %{"question" => "ok?"}}]
           }}
        end,
        invoke_tool: fn _spec -> flunk("deferred tools must not be invoked") end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "check with human"}, host)
      assert result.outputs["status"] == "deferred"

      assert [%{"id" => "d1", "name" => "ask_human", "arguments" => %{"question" => "ok?"}}] =
               result.outputs["deferred_tool_calls"]

      snapshot = result.outputs["session_snapshot"]
      assert is_binary(snapshot) and snapshot != ""

      # Resume: same node, snapshot + human answer in config; the model
      # sees the tool result in history and finishes.
      resume_graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "ignored on resume",
            "max_iterations" => 5,
            "tools" => tools,
            "session_snapshot" => snapshot,
            "deferred_tool_results" =>
              Jason.encode!([%{"tool_call_id" => "d1", "content" => "human says yes"}])
          })
        ],
        "edges" => [edge!("start", "agent_1")]
      }

      resume_host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          assert Enum.any?(
                   request.messages,
                   &(&1[:role] == :tool and &1.content == "human says yes")
                 )

          {:ok, %{content: "Confirmed by the human.", usage: %{}, tool_calls: []}}
        end,
        invoke_tool: fn _spec -> {:ok, %{status: 200, body: %{}, text: ""}} end
      }

      {:ok, resume_built} = Engine.build(resume_graph)
      assert {:ok, resumed} = Engine.run(resume_built, %{"query" => "x"}, resume_host)
      assert resumed.outputs["status"] == "completed"
      assert resumed.outputs["text"] == "Confirmed by the human."
      # Iteration count carried across the deferral.
      assert resumed.outputs["iterations"] == 2
    end

    test "agent node emits part events with the upstream vocabulary" do
      {:ok, events} = Agent.start_link(fn -> [] end)

      tools = [
        %{
          "name" => "lookup",
          "description" => "d",
          "parameters" => %{"type" => "object"},
          "toolset_id" => "ts1",
          "operation_id" => "op"
        }
      ]

      graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "max_iterations" => 3,
            "tools" => tools
          })
        ],
        "edges" => [edge!("start", "agent_1")]
      }

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      host = %Host{
        emit: fn
          {:agent_part, data} -> Elixir.Agent.update(events, &[data | &1])
          _other -> :ok
        end,
        invoke_llm: fn _request, chunk ->
          turn = Elixir.Agent.get_and_update(counter, &{&1, &1 + 1})

          if turn == 0 do
            {:ok,
             %{
               content: "",
               usage: %{},
               tool_calls: [%{id: "c1", name: "lookup", arguments: %{}}]
             }}
          else
            chunk.("final ")
            chunk.("answer")
            {:ok, %{content: "final answer", usage: %{}, tool_calls: []}}
          end
        end,
        invoke_tool: fn _spec -> {:ok, %{status: 200, body: %{}, text: "found"}} end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, _result} = Engine.run(built, %{"query" => "q"}, host)

      parts = events |> Elixir.Agent.get(& &1) |> Enum.reverse()
      types = Enum.map(parts, & &1.type)

      assert "part_start" in types
      assert "part_delta" in types
      assert "function_tool_call" in types
      assert "function_tool_result" in types

      call = Enum.find(parts, &(&1.type == "function_tool_call"))
      assert call.name == "lookup" and call.iteration == 1

      delta = Enum.find(parts, &(&1.type == "part_delta"))
      assert delta.kind == "thinking" and delta.delta == "final "
    end

    test "variable aggregator outputs the first non-empty selector" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("t1", "template", %{"template" => ""}),
          node!("t2", "template", %{"template" => "second wins"}),
          node!("agg", "variable_aggregator", %{
            "variables" => ["t1.output", "t2.output", "start.query"]
          }),
          node!("out", "end", %{"outputs" => [%{"key" => "picked", "value" => "{{agg.output}}"}]})
        ],
        "edges" => [
          edge!("start", "t1"),
          edge!("t1", "t2"),
          edge!("t2", "agg"),
          edge!("agg", "out")
        ]
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, echo_host())
      assert result.outputs == %{"picked" => "second wins"}
    end

    test "variable assigner outputs values and emits conversation_var_set" do
      {:ok, events} = Agent.start_link(fn -> [] end)

      graph = %{
        "nodes" => [
          start_node(),
          node!("assign", "variable_assigner", %{
            "assignments" => [
              %{"name" => "topic", "value" => "{{start.query}}"},
              %{"name" => "", "value" => "dropped"}
            ]
          })
        ],
        "edges" => [edge!("start", "assign")]
      }

      host = %Host{
        emit: fn
          {:conversation_var_set, data} -> Elixir.Agent.update(events, &[data | &1])
          _other -> :ok
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "elixir"}, host)
      assert result.outputs == %{"topic" => "elixir"}
      assert [%{name: "topic", value: "elixir"}] = Elixir.Agent.get(events, & &1)
    end

    test "list operator filters, sorts, and limits" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("code_1", "code", %{"code" => "x", "language" => "python3", "inputs" => []}),
          node!("list", "list_operator", %{
            "variable" => "code_1.items",
            "filter" => %{"operator" => "contains", "value" => "a"},
            "sort" => "asc",
            "limit" => 2
          })
        ],
        "edges" => [edge!("start", "code_1"), edge!("code_1", "list")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        run_code: fn _spec ->
          {:ok, %{result: %{"items" => ["banana", "cherry", "apple", "avocado"]}, stdout: ""}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, host)
      assert result.outputs["output"] == ["apple", "avocado"]
      assert result.outputs["first"] == "apple"
      assert result.outputs["count"] == 2
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
