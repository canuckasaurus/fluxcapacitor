defmodule Flux.PluginRuntimeTest do
  use ExUnit.Case, async: true

  alias Flux.Plugin.ModelProvider.{Chunk, Request, Result}
  alias Flux.PluginRuntime

  test "catalog lists the built-in model providers" do
    ids = PluginRuntime.list_model_providers() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["anthropic", "echo", "gemini", "openai", "openai_compatible"]
  end

  test "gemini manifest and model catalog" do
    {:ok, module} = PluginRuntime.fetch_plugin("gemini")
    manifest = module.manifest()
    assert manifest.name == "Google Gemini"
    assert Enum.any?(manifest.credential_schema, &(&1.key == "api_key"))

    {:ok, models} = PluginRuntime.models("gemini", %{})
    assert Enum.any?(models, &(&1.name == "gemini-2.5-pro"))
  end

  test "unknown plugins are rejected" do
    assert {:error, :unknown_plugin} = PluginRuntime.fetch_plugin("nope")
    assert {:error, :unknown_plugin} = PluginRuntime.validate_credentials("nope", %{})
  end

  test "echo invocation streams chunks and returns the result" do
    parent = self()

    request = %Request{
      model: "echo-1",
      messages: [%{role: :user, content: "runtime check"}]
    }

    assert {:ok, %Result{} = result} =
             PluginRuntime.invoke_llm("echo", %{}, request, fn %Chunk{delta: delta} ->
               send(parent, {:delta, delta})
             end)

    assert result.content =~ "You said: runtime check"
    assert_received {:delta, "You " <> _}
  end

  test "openai manifest declares its credential schema" do
    {:ok, module} = PluginRuntime.fetch_plugin("openai")
    manifest = module.manifest()
    assert Enum.any?(manifest.credential_schema, &(&1.key == "api_key"))
    assert manifest.category == :model
  end
end
