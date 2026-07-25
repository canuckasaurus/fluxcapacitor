defmodule Dify.PluginTest do
  use ExUnit.Case
  doctest Dify.Plugin

  test "greets the world" do
    assert Dify.Plugin.hello() == :world
  end
end
