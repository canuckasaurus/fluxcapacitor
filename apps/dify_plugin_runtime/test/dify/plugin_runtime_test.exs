defmodule Dify.PluginRuntimeTest do
  use ExUnit.Case
  doctest Dify.PluginRuntime

  test "greets the world" do
    assert Dify.PluginRuntime.hello() == :world
  end
end
