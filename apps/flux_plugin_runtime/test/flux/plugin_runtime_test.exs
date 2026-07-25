defmodule Flux.PluginRuntimeTest do
  use ExUnit.Case
  doctest Flux.PluginRuntime

  test "greets the world" do
    assert Flux.PluginRuntime.hello() == :world
  end
end
