defmodule Flux.EngineTest do
  use ExUnit.Case
  doctest Flux.Engine

  test "greets the world" do
    assert Flux.Engine.hello() == :world
  end
end
