defmodule Flux.DelayNodeTest do
  use ExUnit.Case, async: true

  alias Flux.Engine.Graph.Node
  alias Flux.Engine.Nodes.Delay

  defp delay_node(config), do: %Node{id: "delay_1", type: "delay", config: config}

  test "waits the given seconds and reports waited_ms" do
    assert {:ok, %{"waited_ms" => 100}} = Delay.run(delay_node(%{"seconds" => "0.1"}), %{}, nil)
  end

  test "seconds resolve through templates" do
    pool = %{"start" => %{"pause" => "0"}}

    assert {:ok, %{"waited_ms" => 0}} =
             Delay.run(delay_node(%{"seconds" => "{{start.pause}}"}), pool, nil)
  end

  test "an until timestamp in the past waits zero" do
    assert {:ok, %{"waited_ms" => 0}} =
             Delay.run(delay_node(%{"until" => "2020-01-01T00:00:00Z"}), %{}, nil)
  end

  test "delays over the 300s cap are refused" do
    assert {:error, message} = Delay.run(delay_node(%{"seconds" => "301"}), %{}, nil)
    assert message =~ "cap at 300s"
  end

  test "unparseable configs error" do
    assert {:error, _reason} = Delay.run(delay_node(%{"seconds" => "soon"}), %{}, nil)
    assert {:error, _reason} = Delay.run(delay_node(%{"until" => "tomorrow"}), %{}, nil)
    assert {:error, _reason} = Delay.run(delay_node(%{}), %{}, nil)
  end

  test "delay is a registered node type" do
    assert Flux.Engine.Node.implementation("delay") == Delay
    assert "delay" in Flux.Engine.Graph.node_types()
  end
end
