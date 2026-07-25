defmodule Dify.EngineTest do
  use ExUnit.Case
  doctest Dify.Engine

  test "greets the world" do
    assert Dify.Engine.hello() == :world
  end
end
