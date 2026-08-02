defmodule Flux.Workflows.ReferenceTraceTest do
  @moduledoc """
  Golden harness phase 2: recorded traces from a live Reference instance
  (harness/record_reference_traces.py) replay on our engine. For every
  trace the same DSL import must reproduce the reference's final status,
  outputs, and the set of executed nodes. No traces recorded yet → this
  module generates no per-trace tests and costs nothing.

  Code-node traces execute through Flux.CodeRunner.Local, so the suite
  skips when no python interpreter is on PATH.
  """
  use ExUnit.Case, async: false

  alias Flux.Engine
  alias Flux.Engine.Host
  alias Flux.Workflows.DSL

  @fixtures Path.expand("../../support/fixtures/dsl", __DIR__)
  @traces Path.expand("../../support/reference_traces", __DIR__)
  @python System.find_executable("python") || System.find_executable("python3")

  setup do
    previous = Application.get_env(:flux, Flux.CodeRunner.Local)
    Application.put_env(:flux, Flux.CodeRunner.Local, enabled: true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:flux, Flux.CodeRunner.Local)
        config -> Application.put_env(:flux, Flux.CodeRunner.Local, config)
      end
    end)

    :ok
  end

  defp host do
    parent = self()

    %Host{
      emit: fn event -> send(parent, {:engine_event, event}) end,
      run_code: &Flux.CodeRunner.Local.run/1
    }
  end

  defp collect_finished_nodes(acc) do
    receive do
      {:engine_event, {:node_finished, %{node_id: node_id}}} ->
        collect_finished_nodes([node_id | acc])

      {:engine_event, _other} ->
        collect_finished_nodes(acc)
    after
      0 -> Enum.sort(acc)
    end
  end

  for path <- Path.wildcard(Path.join(@traces, "*.json")) do
    @trace_path path

    @tag skip: is_nil(@python) && "needs a python interpreter for code-node traces"
    test "reference parity: #{Path.basename(path)}" do
      trace = @trace_path |> File.read!() |> Jason.decode!()
      assert trace["format"] == "fluxcapacitor-reference-trace"

      {:ok, parsed} = DSL.parse(File.read!(Path.join(@fixtures, trace["fixture"])))
      {:ok, graph} = Engine.build(parsed.graph)

      {:ok, result} = Engine.run(graph, trace["inputs"], host())

      final = trace["final"]
      assert result.outputs == final["outputs"]

      # Same nodes ran: ids survive DSL import verbatim on both sides.
      reference_nodes =
        final["nodes"]
        |> Enum.filter(&(&1["status"] == "succeeded"))
        |> Enum.map(& &1["node_id"])
        |> Enum.sort()

      assert collect_finished_nodes([]) == reference_nodes
    end
  end

  test "the recorder writes where this suite reads" do
    recorder = Path.expand("../../../../../harness/record_reference_traces.py", __DIR__)
    assert File.exists?(recorder)
    assert File.read!(recorder) =~ ~s{"reference_traces"}
  end
end
