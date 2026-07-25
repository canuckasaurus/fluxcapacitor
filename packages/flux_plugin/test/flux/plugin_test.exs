defmodule Flux.PluginTest do
  use ExUnit.Case
  doctest Flux.Plugin

  test "greets the world" do
    assert Flux.Plugin.hello() == :world
  end
end
