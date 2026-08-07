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

    test "rejects bad if_else handles; multiple edges per handle fan out" do
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

      # Two edges on one handle are legal now: parallel fan-out.
      graph = %{
        "nodes" => [start_node(), node!("a", "answer"), node!("b", "answer")],
        "edges" => [edge!("start", "a"), %{"id" => "dup", "source" => "start", "target" => "b"}]
      }

      assert {:ok, _built} = Engine.build(graph)
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

    test "template node renders jinja when the engine mode says so" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("t", "template", %{
            "engine" => "jinja",
            "template" =>
              "{% if start.query == 'list' %}{% for n in start.items %}{{ n }}-{% endfor %}" <>
                "{% else %}{{ start.query | upper }}{% endif %}"
          })
        ],
        "edges" => [edge!("start", "t")]
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, %{outputs: %{"output" => "HELLO"}}} =
               Engine.run(built, %{"query" => "hello"}, echo_host())

      # Jinja syntax errors fail the node loudly.
      bad =
        put_in(graph, ["nodes"], [
          start_node(),
          node!("t", "template", %{"engine" => "jinja", "template" => "{% if x %}oops"})
        ])

      {:ok, built} = Engine.build(bad)
      assert {:error, failure} = Engine.run(built, %{"query" => "q"}, echo_host())
      assert failure.error =~ "jinja"
    end

    test "template node pulls a saved doc template through the host" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("t", "template", %{"template_id" => "tpl-1"})
        ],
        "edges" => [edge!("start", "t")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        fetch_doc_template: fn
          "tpl-1" -> {:ok, "Dear {{ start.query | capitalize }}, welcome."}
          _other -> {:error, "doc template not found"}
        end
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, %{outputs: %{"output" => "Dear Marty, welcome."}}} =
               Engine.run(built, %{"query" => "marty"}, host)

      missing =
        put_in(graph, ["nodes"], [
          start_node(),
          node!("t", "template", %{"template_id" => "ghost"})
        ])

      {:ok, built} = Engine.build(missing)
      assert {:error, failure} = Engine.run(built, %{"query" => "q"}, host)
      assert failure.error =~ "not found"
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

    test "parallel fan-out runs branches concurrently and merges at the join" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("a", "llm", %{"provider_plugin_id" => "p", "model" => "m", "prompt" => "left"}),
          node!("b", "llm", %{"provider_plugin_id" => "p", "model" => "m", "prompt" => "right"}),
          node!("join", "template", %{"template" => "{{a.text}}+{{b.text}}"})
        ],
        "edges" => [
          edge!("start", "a"),
          edge!("start", "b"),
          edge!("a", "join"),
          edge!("b", "join")
        ]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          Process.sleep(150)
          [%{content: prompt} | _] = Enum.reverse(request.messages)
          {:ok, %{content: "r:" <> prompt, usage: %{}}}
        end
      }

      {:ok, built} = Engine.build(graph)
      started = System.monotonic_time(:millisecond)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, host)
      elapsed = System.monotonic_time(:millisecond) - started

      assert result.outputs == %{"output" => "r:left+r:right"}
      # Two 150ms model calls in parallel finish well under the 300ms a
      # sequential walk would need.
      assert elapsed < 280

      statuses = Enum.map(result.node_executions, &{&1["node_id"], &1["status"]})
      assert {"a", "succeeded"} in statuses
      assert {"b", "succeeded"} in statuses
      assert {"join", "succeeded"} in statuses
      # The join executed exactly once.
      assert Enum.count(result.node_executions, &(&1["node_id"] == "join")) == 1
    end

    test "parallel branches without a join merge their final outputs" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("left", "end", %{"outputs" => [%{"key" => "l", "value" => "1"}]}),
          node!("right", "end", %{"outputs" => [%{"key" => "r", "value" => "2"}]})
        ],
        "edges" => [edge!("start", "left"), edge!("start", "right")]
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, echo_host())
      assert result.outputs == %{"l" => "1", "r" => "2"}
    end

    test "an error in one parallel branch fails the run" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("ok_branch", "template", %{"template" => "fine"}),
          node!("bad", "llm", %{"provider_plugin_id" => "", "model" => ""}),
          node!("join", "template", %{"template" => "{{ok_branch.output}}"})
        ],
        "edges" => [
          edge!("start", "ok_branch"),
          edge!("start", "bad"),
          edge!("ok_branch", "join"),
          edge!("bad", "join")
        ]
      }

      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "q"}, echo_host())
      assert failure.node_id == "bad"
      assert failure.error =~ "provider and model"
    end

    test "human input inside parallel branches is refused" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("ask", "human_input", %{"prompt" => "well?"}),
          node!("calm", "template", %{"template" => "ok"}),
          node!("join", "template", %{"template" => "{{calm.output}}"})
        ],
        "edges" => [
          edge!("start", "ask"),
          edge!("start", "calm"),
          edge!("ask", "join"),
          edge!("calm", "join")
        ]
      }

      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "q"}, echo_host())
      assert failure.error =~ "parallel branches"
    end

    test "loop node repeats the sub-flux until the break condition matches" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("refine", "loop", %{
            "workflow_id" => "wf-sub",
            "initial" => "{{start.query}}",
            "max_loops" => 10,
            "conditions" => [
              %{"left" => "{{refine.score}}", "operator" => "gte", "right" => "3"}
            ]
          }),
          node!("out", "answer", %{
            "answer" => "rounds={{refine.rounds}} met={{refine.condition_met}}"
          })
        ],
        "edges" => [edge!("start", "refine"), edge!("refine", "out")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        # Each round scores index + 1: rounds 1..3 score 1,2,3 → break at 3.
        run_subflux: fn %{workflow_id: "wf-sub", index: index} ->
          {:ok, %{"score" => index + 1, "draft" => "v#{index + 1}"}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "polish this"}, host)
      assert result.outputs["answer"] == "rounds=3 met=true"

      loop_exec = Enum.find(result.node_executions, &(&1["node_id"] == "refine"))
      assert loop_exec["outputs"]["rounds"] == 3
      assert loop_exec["outputs"]["output"]["draft"] == "v3"
      assert length(loop_exec["outputs"]["history"]) == 3
    end

    test "loop node without conditions runs exactly max_loops rounds" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("l", "loop", %{"workflow_id" => "wf-sub", "max_loops" => 4})
        ],
        "edges" => [edge!("start", "l")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        run_subflux: fn %{index: index} -> {:ok, %{"n" => index}} end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, host)
      assert result.outputs["rounds"] == 4
      assert result.outputs["condition_met"] == false

      # Sub-flux failures halt the loop with the round number.
      failing_host = %Host{
        emit: fn _e -> :ok end,
        run_subflux: fn
          %{index: 1} -> {:error, "boom"}
          %{index: index} -> {:ok, %{"n" => index}}
        end
      }

      assert {:error, failure} = Engine.run(built, %{"query" => "q"}, failing_host)
      assert failure.error =~ "round 2: boom"
    end

    test "llm node falls back to the configured backup model" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("llm_1", "llm", %{
            "provider_plugin_id" => "down",
            "model" => "primary-1",
            "fallback_provider_plugin_id" => "backup",
            "fallback_model" => "backup-1",
            "prompt" => "{{start.query}}"
          })
        ],
        "edges" => [edge!("start", "llm_1")]
      }

      host = %Host{
        emit: fn event -> send(self(), {:event, event}) end,
        invoke_llm: fn
          %{provider_plugin_id: "down"}, _chunk ->
            {:error, "provider outage"}

          %{provider_plugin_id: "backup"} = request, _chunk ->
            [%{content: prompt} | _] = Enum.reverse(request.messages)
            {:ok, %{content: "saved: " <> prompt, usage: %{}}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "hi"}, host)
      assert result.outputs["text"] == "saved: hi"
      assert result.outputs["fallback_used"] == true
      assert result.outputs["model_used"] == "backup/backup-1"
      assert_received {:event, {:model_fallback, %{from: "down/primary-1"}}}

      # Both failing surfaces the primary's error.
      dead_host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn _request, _chunk -> {:error, "provider outage"} end
      }

      assert {:error, failure} = Engine.run(built, %{"query" => "hi"}, dead_host)
      assert failure.error =~ "provider outage"
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

    test "code node passes attachments through and stores returned artifacts" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("code_1", "code", %{
            "language" => "python3",
            "code" => "def main(): return {}",
            "attachments" => [
              %{"file_id" => "{{start.query}}", "name" => "model.joblib"},
              %{"file_id" => ""}
            ]
          }),
          node!("end_1", "end", %{
            "outputs" => [%{"key" => "files", "value" => "{{code_1.files}}"}]
          })
        ],
        "edges" => [edge!("start", "code_1"), edge!("code_1", "end_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        run_code: fn spec ->
          assert spec.attachments == [%{"file_id" => "file-abc", "name" => "model.joblib"}]

          {:ok,
           %{
             result: %{"trained" => true},
             stdout: "",
             artifacts: [%{name: "model.joblib", binary: <<1, 2, 3>>}]
           }}
        end,
        store_file: fn %{name: name, binary: <<1, 2, 3>>} ->
          {:ok, %{"file_id" => "stored-1", "name" => name, "url" => "/files/tok", "size" => 3}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "file-abc"}, host)

      code_execution = Enum.find(result.node_executions, &(&1["node_id"] == "code_1"))

      assert [%{"file_id" => "stored-1", "name" => "model.joblib"}] =
               code_execution["outputs"]["files"]
    end

    test "file_output node renders content, wraps HTML, and stores through the host" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("file_1", "file_output", %{
            "format" => "html",
            "content" => "<h1>{{start.query}}</h1>",
            "output_name" => "report-{{start.query}}"
          }),
          node!("end_1", "end", %{"outputs" => [%{"key" => "url", "value" => "{{file_1.url}}"}]})
        ],
        "edges" => [edge!("start", "file_1"), edge!("file_1", "end_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        store_file: fn %{name: name, binary: binary, format: "html"} ->
          assert name == "report-gigawatts.html"
          assert binary =~ "<!DOCTYPE html>"
          assert binary =~ "<h1>gigawatts</h1>"
          {:ok, %{"file_id" => "f1", "name" => name, "url" => "/files/tok", "size" => 1}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "gigawatts"}, host)
      assert result.outputs == %{"url" => "/files/tok"}

      file_execution = Enum.find(result.node_executions, &(&1["node_id"] == "file_1"))
      assert file_execution["outputs"]["format"] == "html"
    end

    test "file_output passes full HTML pages and raw formats through untouched" do
      full_page = "<html><body>as-is</body></html>"

      graph = %{
        "nodes" => [
          start_node(),
          node!("file_1", "file_output", %{"format" => "pdf", "content" => full_page})
        ],
        "edges" => [edge!("start", "file_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        store_file: fn %{name: "output.pdf", binary: ^full_page, format: "html_pdf"} ->
          {:ok, %{"file_id" => "f1", "name" => "output.pdf", "url" => "/files/t", "size" => 1}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, _result} = Engine.run(built, %{"query" => "x"}, host)

      md_graph = %{
        "nodes" => [
          start_node(),
          node!("file_1", "file_output", %{
            "format" => "markdown",
            "content" => "# {{start.query}}",
            "output_name" => "notes.md"
          })
        ],
        "edges" => [edge!("start", "file_1")]
      }

      md_host = %Host{
        emit: fn _e -> :ok end,
        store_file: fn %{name: "notes.md", binary: "# hi", format: "raw"} ->
          {:ok, %{"file_id" => "f2", "name" => "notes.md", "url" => "/files/t2", "size" => 4}}
        end
      }

      {:ok, md_built} = Engine.build(md_graph)
      assert {:ok, _result} = Engine.run(md_built, %{"query" => "hi"}, md_host)
    end

    test "file_output fails honestly on empty content, unknown format, or no capability" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("file_1", "file_output", %{"format" => "html", "content" => ""})
        ],
        "edges" => [edge!("start", "file_1")]
      }

      host = %Host{emit: fn _e -> :ok end, store_file: fn _r -> {:ok, %{}} end}
      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "x"}, host)
      assert failure.error =~ "empty content"

      bad_format = %{
        "nodes" => [
          start_node(),
          node!("file_1", "file_output", %{"format" => "exe", "content" => "x"})
        ],
        "edges" => [edge!("start", "file_1")]
      }

      {:ok, bad_built} = Engine.build(bad_format)
      assert {:error, failure} = Engine.run(bad_built, %{"query" => "x"}, host)
      assert failure.error =~ "unknown output format"

      assert {:error, failure} = Engine.run(built, %{"query" => "x"}, echo_host())
      assert failure.error =~ "cannot store files"
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

    test "agent drive: write, list, and read files across iterations" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "max_iterations" => 4,
            "enable_drive" => true,
            "tools" => []
          })
        ],
        "edges" => [edge!("start", "agent_1")]
      }

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          turn = Elixir.Agent.get_and_update(counter, &{&1, &1 + 1})

          case turn do
            0 ->
              # The drive tools are offered when enabled.
              names = Enum.map(request.tools, & &1["name"])
              assert "drive_write" in names and "drive_read" in names and "drive_list" in names

              {:ok,
               %{
                 content: "",
                 usage: %{},
                 tool_calls: [
                   %{
                     id: "w1",
                     name: "drive_write",
                     arguments: %{"name" => "notes.md", "content" => "remember the milk"}
                   },
                   %{id: "l1", name: "drive_list", arguments: %{}}
                 ]
               }}

            1 ->
              # Both drive results are in history: the write ack and the listing.
              tool_contents =
                for %{role: :tool} = message <- request.messages, do: message.content

              assert Enum.any?(tool_contents, &(&1 =~ "wrote notes.md"))
              assert Enum.any?(tool_contents, &(&1 =~ "notes.md (17 bytes)"))

              {:ok,
               %{
                 content: "",
                 usage: %{},
                 tool_calls: [
                   %{id: "r1", name: "drive_read", arguments: %{"name" => "notes.md"}}
                 ]
               }}

            _final ->
              assert Enum.any?(
                       request.messages,
                       &(&1[:role] == :tool and &1.content == "remember the milk")
                     )

              {:ok, %{content: "done", usage: %{}, tool_calls: []}}
          end
        end,
        invoke_tool: fn _spec -> flunk("drive calls must not reach invoke_tool") end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "take notes"}, host)
      assert result.outputs["text"] == "done"
      assert result.outputs["files"] == %{"notes.md" => "remember the milk"}

      # Without enable_drive the tools are not offered and files stay empty.
      graph2 =
        put_in(
          graph,
          ["nodes"],
          List.update_at(graph["nodes"], 1, fn node ->
            put_in(node, ["config", "enable_drive"], false)
          end)
        )

      host2 = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          assert request.tools == []
          {:ok, %{content: "plain", usage: %{}, tool_calls: []}}
        end,
        invoke_tool: fn _spec -> {:ok, %{status: 200, body: %{}, text: ""}} end
      }

      {:ok, built2} = Engine.build(graph2)
      assert {:ok, result2} = Engine.run(built2, %{"query" => "q"}, host2)
      assert result2.outputs["files"] == %{}
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

    test "question classifier routes on the tool-reported class" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("qc", "question_classifier", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "classes" => [
              %{"id" => "billing", "name" => "Billing questions"},
              %{"id" => "support", "name" => "Technical support"}
            ]
          }),
          node!("billing_end", "template", %{"template" => "billing branch"}),
          node!("support_end", "template", %{"template" => "support branch"})
        ],
        "edges" => [
          edge!("start", "qc"),
          %{
            "id" => "e_billing",
            "source" => "qc",
            "source_handle" => "billing",
            "target" => "billing_end"
          },
          %{
            "id" => "e_support",
            "source" => "qc",
            "source_handle" => "support",
            "target" => "support_end"
          }
        ]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          assert Enum.any?(request.tools, &(&1["name"] == "classify"))

          {:ok,
           %{
             content: "",
             usage: %{},
             tool_calls: [
               %{id: "c1", name: "classify", arguments: %{"class_id" => "support"}}
             ]
           }}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "my app crashes"}, host)
      assert result.outputs["output"] == "support branch"

      assert Enum.any?(
               result.node_executions,
               &(&1["node_id"] == "qc" and &1["outputs"]["class_id"] == "support")
             )
    end

    test "classifier rejects edges on unknown class handles" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("qc", "question_classifier", %{
            "classes" => [%{"id" => "a", "name" => "A"}]
          }),
          node!("t", "template", %{"template" => "x"})
        ],
        "edges" => [
          edge!("start", "qc"),
          %{"id" => "bad", "source" => "qc", "source_handle" => "nope", "target" => "t"}
        ]
      }

      assert {:error, errors} = Engine.build(graph)
      assert Enum.any?(errors, &(&1 =~ "handle nope"))
    end

    test "parameter extractor coerces types and reports success" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("px", "parameter_extractor", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "parameters" => [
              %{"name" => "city", "type" => "string", "required" => true},
              %{"name" => "days", "type" => "number", "required" => false}
            ]
          })
        ],
        "edges" => [edge!("start", "px")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          [tool] = request.tools
          assert tool["name"] == "extract"
          assert tool["parameters"]["required"] == ["city"]

          {:ok,
           %{
             content: "",
             usage: %{},
             tool_calls: [
               %{
                 id: "e1",
                 name: "extract",
                 arguments: %{"city" => "Paris", "days" => "3"}
               }
             ]
           }}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "3 days in Paris"}, host)
      assert result.outputs["city"] == "Paris"
      assert result.outputs["days"] == 3
      assert result.outputs["is_success"] == true
    end

    test "parameter extractor flags missing required fields" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("px", "parameter_extractor", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "parameters" => [%{"name" => "email", "type" => "string", "required" => true}]
          })
        ],
        "edges" => [edge!("start", "px")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn _request, _chunk ->
          {:ok,
           %{
             content: "",
             usage: %{},
             tool_calls: [%{id: "e1", name: "extract", arguments: %{}}]
           }}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "no email here"}, host)
      assert result.outputs["is_success"] == false
      assert result.outputs["reason"] =~ "email"
    end

    test "a failing node retries up to max_retries and can still succeed" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      graph = %{
        "nodes" => [
          start_node(),
          node!("llm_1", "llm", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "prompt" => "{{start.query}}",
            "retry" => %{"max_retries" => 2, "interval_ms" => 0}
          })
        ],
        "edges" => [edge!("start", "llm_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn _request, _chunk ->
          attempt = Elixir.Agent.get_and_update(counter, &{&1, &1 + 1})

          if attempt < 2 do
            {:error, "flaky"}
          else
            {:ok, %{content: "third time lucky", usage: %{}, tool_calls: []}}
          end
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, host)
      assert result.outputs["text"] == "third time lucky"
      assert Elixir.Agent.get(counter, & &1) == 3
    end

    test "a failed node with an error edge routes the error branch" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("llm_1", "llm", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "prompt" => "{{start.query}}"
          }),
          node!("fallback", "template", %{
            "template" => "fallback because: {{llm_1.error}}"
          })
        ],
        "edges" => [
          edge!("start", "llm_1"),
          %{
            "id" => "e_err",
            "source" => "llm_1",
            "source_handle" => "error",
            "target" => "fallback"
          }
        ]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn _request, _chunk -> {:error, "provider down"} end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, host)
      assert result.outputs["output"] == "fallback because: provider down"

      assert Enum.any?(
               result.node_executions,
               &(&1["node_id"] == "llm_1" and &1["status"] == "failed")
             )
    end

    test "a failed node without an error edge still fails the run" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("llm_1", "llm", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "prompt" => "{{start.query}}"
          })
        ],
        "edges" => [edge!("start", "llm_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn _request, _chunk -> {:error, "provider down"} end
      }

      {:ok, built} = Engine.build(graph)
      assert {:error, failure} = Engine.run(built, %{"query" => "q"}, host)
      assert failure.node_id == "llm_1"
    end

    test "env, sys, and conversation variables resolve in templates" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("assign", "variable_assigner", %{
            "assignments" => [%{"name" => "greeted", "value" => "yes"}]
          }),
          node!("t", "template", %{
            "template" =>
              "env={{env.API_BASE}} sys={{sys.query}} conv={{conversation.topic}} set={{conversation.greeted}}"
          })
        ],
        "edges" => [edge!("start", "assign"), edge!("assign", "t")],
        "env" => %{"API_BASE" => "https://api.example.com"},
        "conversation_variables" => [
          %{"name" => "topic", "default" => "general"},
          %{"name" => "greeted", "default" => "no"}
        ]
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, result} =
               Engine.run(built, %{"query" => "q"}, echo_host(), sys: %{"query" => "from sys"})

      assert result.outputs["output"] ==
               "env=https://api.example.com sys=from sys conv=general set=yes"
    end

    test "reserved node ids are rejected" do
      graph = %{
        "nodes" => [start_node(), node!("env", "template", %{"template" => "x"})],
        "edges" => [edge!("start", "env")]
      }

      assert {:error, errors} = Engine.build(graph)
      assert Enum.any?(errors, &(&1 =~ "reserved"))
    end

    test "document extractor reads text through the host" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("doc", "document_extractor", %{"variable" => "start.query"})
        ],
        "edges" => [edge!("start", "doc")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        read_document: fn %{file_id: "file-123"} ->
          {:ok, %{text: "extracted contents", name: "notes.txt", size: 18}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "file-123"}, host)
      assert result.outputs["text"] == "extracted contents"
      assert result.outputs["name"] == "notes.txt"
    end

    test "iteration node maps items through the run_subflux capability" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("code_1", "code", %{"code" => "x", "language" => "python3", "inputs" => []}),
          node!("iter", "iteration", %{
            "variable" => "code_1.items",
            "workflow_id" => "wf-sub",
            "max_items" => 10
          })
        ],
        "edges" => [edge!("start", "code_1"), edge!("code_1", "iter")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        run_code: fn _spec -> {:ok, %{result: %{"items" => ["a", "b"]}, stdout: ""}} end,
        run_subflux: fn %{workflow_id: "wf-sub", item: item, index: index} ->
          {:ok, %{"echoed" => "#{index}:#{item}"}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, host)
      assert result.outputs["count"] == 2
      assert result.outputs["output"] == [%{"echoed" => "0:a"}, %{"echoed" => "1:b"}]
    end

    test "cache_minutes memoizes node outputs through the host cache" do
      {:ok, store} = Agent.start_link(fn -> %{store: %{}, calls: 0} end)

      cache = %{
        get: fn key -> Agent.get(store, &(Map.fetch(&1.store, key) || :miss)) end,
        put: fn key, value, _ttl ->
          Agent.update(store, &put_in(&1.store[key], value))
        end
      }

      graph = %{
        "nodes" => [
          start_node(),
          node!("http_1", "http_request", %{
            "method" => "get",
            "url" => "https://api.example.com/x",
            "cache_minutes" => 10
          })
        ],
        "edges" => [edge!("start", "http_1")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        node_cache: cache,
        http_request: fn _request ->
          Agent.update(store, &%{&1 | calls: &1.calls + 1})
          {:ok, %{status: 200, body: "pong", text: "pong"}}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, first} = Engine.run(built, %{"query" => "q"}, host)
      assert {:ok, second} = Engine.run(built, %{"query" => "q"}, host)

      # Same pool + config → the second run never hit the HTTP capability.
      assert Agent.get(store, & &1.calls) == 1
      assert first.outputs == second.outputs

      # A different upstream pool busts the key conservatively.
      assert {:ok, _third} = Engine.run(built, %{"query" => "different"}, host)
      assert Agent.get(store, & &1.calls) == 2
    end

    test "iteration and loop pass a subflux_version pin through to the host" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("iter", "iteration", %{
            "variable" => "start.query",
            "workflow_id" => "wf-sub",
            "subflux_version" => "v3"
          })
        ],
        "edges" => [edge!("start", "iter")]
      }

      pin_host = %Host{
        emit: fn _e -> :ok end,
        run_subflux: fn request -> {:ok, %{"got" => request[:version]}} end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => ~s(["a"])}, pin_host)
      assert result.outputs["output"] == [%{"got" => 3}]

      loop_graph = %{
        "nodes" => [
          start_node(),
          node!("loop", "loop", %{
            "workflow_id" => "wf-sub",
            "initial" => "x",
            "max_loops" => 1,
            "subflux_version" => 2,
            "conditions" => []
          })
        ],
        "edges" => [edge!("start", "loop")]
      }

      {:ok, built} = Engine.build(loop_graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "q"}, pin_host)
      assert result.outputs["output"] == %{"got" => 2}

      # Blank and junk pins mean "latest" — no :version key at all.
      assert Flux.Engine.Nodes.SubfluxVersion.parse("") == nil
      assert Flux.Engine.Nodes.SubfluxVersion.parse("latest") == nil
      assert Flux.Engine.Nodes.SubfluxVersion.parse("v0") == nil
      assert Flux.Engine.Nodes.SubfluxVersion.parse(" v12 ") == 12
    end

    test "iteration node enforces max_items and reports item failures" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("iter", "iteration", %{
            "variable" => "start.query",
            "workflow_id" => "wf-sub",
            "max_items" => 2
          })
        ],
        "edges" => [edge!("start", "iter")]
      }

      failing_host = %Host{
        emit: fn _e -> :ok end,
        run_subflux: fn %{index: index} ->
          if index == 1, do: {:error, "boom"}, else: {:ok, %{}}
        end
      }

      {:ok, built} = Engine.build(graph)

      # JSON list in a start variable is decoded; over-limit is rejected.
      assert {:error, failure} =
               Engine.run(built, %{"query" => ~s(["a","b","c"])}, failing_host)

      assert failure.error =~ "max_items"

      assert {:error, failure} = Engine.run(built, %{"query" => ~s(["a","b"])}, failing_host)
      assert failure.error =~ "item 1: boom"
    end

    test "human_input pauses the run and resume continues from its output" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("ask", "human_input", %{
            "prompt" => "Approve {{start.query}}?",
            "options" => ["yes", "no"]
          }),
          node!("t", "template", %{"template" => "human said: {{ask.output}}"})
        ],
        "edges" => [edge!("start", "ask"), edge!("ask", "t")]
      }

      {:ok, built} = Engine.build(graph)

      assert {:paused, paused} = Engine.run(built, %{"query" => "the deploy"}, echo_host())
      assert paused.node_id == "ask"
      assert paused.prompt["prompt"] == "Approve the deploy?"
      assert paused.prompt["options"] == ["yes", "no"]

      assert {:ok, result} =
               Engine.run(built, %{}, echo_host(),
                 resume: %{pool: paused.pool, node_id: "ask", input: "yes"}
               )

      assert result.outputs["output"] == "human said: yes"
    end

    test "agent tool approval pauses, then approve executes and deny refuses" do
      tools = [
        %{
          "name" => "send_alert",
          "description" => "d",
          "parameters" => %{"type" => "object"},
          "toolset_id" => "ts1",
          "operation_id" => "sendAlert"
        }
      ]

      graph = %{
        "nodes" => [
          start_node(),
          node!("agent_1", "agent", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "query" => "{{start.query}}",
            "max_iterations" => 4,
            "tools" => tools,
            "approval_tools" => ["send_alert"]
          }),
          node!("end_1", "end", %{
            "outputs" => [%{"key" => "answer", "value" => "{{agent_1.text}}"}]
          })
        ],
        "edges" => [edge!("start", "agent_1"), edge!("agent_1", "end_1")]
      }

      test_pid = self()

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          if Enum.any?(request.messages, &(&1.role == :tool)) do
            [tool_message | _] = for %{role: :tool} = m <- request.messages, do: m
            {:ok, %{content: "done: #{tool_message.content}", usage: %{}}}
          else
            {:ok,
             %{
               content: nil,
               tool_calls: [%{id: "c1", name: "send_alert", arguments: %{"to" => "doc"}}],
               usage: %{}
             }}
          end
        end,
        invoke_tool: fn spec ->
          send(test_pid, {:tool_executed, spec})
          {:ok, %{status: 200, body: %{}, text: "alert sent"}}
        end
      }

      {:ok, built} = Engine.build(graph)

      assert {:paused, paused} = Engine.run(built, %{"query" => "warn doc"}, host)
      assert paused.node_id == "agent_1"
      assert paused.prompt["type"] == "tool_approval"
      assert paused.prompt["prompt"] =~ "send_alert"
      assert [%{"name" => "send_alert"}] = paused.prompt["pending"]
      refute_received {:tool_executed, _spec}

      # Approve: the tool executes and the loop finishes with its result.
      assert {:ok, result} =
               Engine.run(built, %{}, host,
                 resume: %{
                   pool: paused.pool,
                   node_id: "agent_1",
                   input: %{"approved" => true, "prompt" => paused.prompt},
                   rerun: true
                 }
               )

      assert_received {:tool_executed, %{operation_id: "sendAlert"}}
      assert result.outputs["answer"] == "done: alert sent"

      # Deny: no execution, the refusal reaches the model instead.
      assert {:ok, denied} =
               Engine.run(built, %{}, host,
                 resume: %{
                   pool: paused.pool,
                   node_id: "agent_1",
                   input: %{"approved" => false, "prompt" => paused.prompt},
                   rerun: true
                 }
               )

      refute_received {:tool_executed, _spec}
      assert denied.outputs["answer"] =~ "denied"
    end

    test "multi-case if_else routes the first matching case, else falls through" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("branch", "if_else", %{
            "cases" => [
              %{
                "id" => "greeting",
                "logical_operator" => "and",
                "conditions" => [
                  %{"left" => "{{start.query}}", "operator" => "contains", "right" => "hello"}
                ]
              },
              %{
                "id" => "farewell",
                "logical_operator" => "and",
                "conditions" => [
                  %{"left" => "{{start.query}}", "operator" => "contains", "right" => "bye"}
                ]
              }
            ]
          }),
          node!("t_greet", "template", %{"template" => "greeting branch"}),
          node!("t_bye", "template", %{"template" => "farewell branch"}),
          node!("t_else", "template", %{"template" => "else branch"})
        ],
        "edges" => [
          edge!("start", "branch"),
          %{
            "id" => "e1",
            "source" => "branch",
            "source_handle" => "greeting",
            "target" => "t_greet"
          },
          %{
            "id" => "e2",
            "source" => "branch",
            "source_handle" => "farewell",
            "target" => "t_bye"
          },
          %{"id" => "e3", "source" => "branch", "source_handle" => "false", "target" => "t_else"}
        ]
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, result} = Engine.run(built, %{"query" => "hello there"}, echo_host())
      assert result.outputs["output"] == "greeting branch"

      assert {:ok, result} = Engine.run(built, %{"query" => "bye now"}, echo_host())
      assert result.outputs["output"] == "farewell branch"

      assert {:ok, result} = Engine.run(built, %{"query" => "neither"}, echo_host())
      assert result.outputs["output"] == "else branch"
    end

    test "legacy flat if_else configs keep the true/false contract" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("branch", "if_else", %{
            "logical_operator" => "and",
            "conditions" => [
              %{"left" => "{{start.query}}", "operator" => "contains", "right" => "yes"}
            ]
          }),
          node!("t_true", "template", %{"template" => "T"}),
          node!("t_false", "template", %{"template" => "F"})
        ],
        "edges" => [
          edge!("start", "branch"),
          %{"id" => "e1", "source" => "branch", "source_handle" => "true", "target" => "t_true"},
          %{"id" => "e2", "source" => "branch", "source_handle" => "false", "target" => "t_false"}
        ]
      }

      {:ok, built} = Engine.build(graph)

      assert {:ok, %{outputs: %{"output" => "T"}}} =
               Engine.run(built, %{"query" => "yes"}, echo_host())

      assert {:ok, %{outputs: %{"output" => "F"}}} =
               Engine.run(built, %{"query" => "no"}, echo_host())
    end

    test "llm node with output_schema yields structured output via the respond tool" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("llm_1", "llm", %{
            "provider_plugin_id" => "p",
            "model" => "m",
            "prompt" => "{{start.query}}",
            "output_schema" => %{
              "type" => "object",
              "properties" => %{"sentiment" => %{"type" => "string"}}
            }
          }),
          node!("t", "template", %{"template" => "got {{llm_1.output.sentiment}}"})
        ],
        "edges" => [edge!("start", "llm_1"), edge!("llm_1", "t")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        invoke_llm: fn request, _chunk ->
          assert [%{"name" => "respond"}] = request.tools

          {:ok,
           %{
             content: "",
             usage: %{},
             tool_calls: [
               %{id: "r1", name: "respond", arguments: %{"sentiment" => "positive"}}
             ]
           }}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "love it"}, host)
      assert result.outputs["output"] == "got positive"
    end

    test "knowledge retrieval node joins hits and exposes citations" do
      graph = %{
        "nodes" => [
          start_node(),
          node!("kb", "knowledge_retrieval", %{
            "dataset_id" => "ds-1",
            "query" => "{{start.query}}",
            "top_k" => 2
          }),
          node!("a", "answer", %{"answer" => "Context:\n{{kb.result}}"})
        ],
        "edges" => [edge!("start", "kb"), edge!("kb", "a")]
      }

      host = %Host{
        emit: fn _e -> :ok end,
        retrieve_knowledge: fn %{dataset_ids: ["ds-1"], query: "vacation days", top_k: 2} ->
          {:ok,
           [
             %{content: "25 paid days per year.", document_name: "handbook.md", score: 0.9},
             %{content: "Days roll over one quarter.", document_name: "handbook.md", score: 0.5}
           ]}
        end
      }

      {:ok, built} = Engine.build(graph)
      assert {:ok, result} = Engine.run(built, %{"query" => "vacation days"}, host)
      assert result.outputs["answer"] =~ "25 paid days per year."
      assert result.outputs["answer"] =~ "Days roll over"

      kb = Enum.find(result.node_executions, &(&1["node_id"] == "kb"))
      assert kb["outputs"]["count"] == 2
      assert [%{"document" => "handbook.md"} | _] = kb["outputs"]["citations"]
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
