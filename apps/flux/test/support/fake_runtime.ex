defmodule Flux.FakeRuntime do
  @moduledoc """
  Test double for `Flux.PluginRuntime` used by core (`apps/flux`) tests —
  the real runtime lives in an app core doesn't depend on. Mirrors the Echo
  provider's observable behaviour; flux_web tests exercise the real runtime.
  """

  alias Flux.Plugin.Manifest
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec}

  @echo %Manifest{
    id: "echo",
    name: "Echo (dev)",
    version: "0.1.0",
    category: :model,
    credential_schema: []
  }

  @openai %Manifest{
    id: "openai",
    name: "OpenAI",
    version: "0.1.0",
    category: :model,
    credential_schema: [
      %Flux.Plugin.CredentialField{key: "api_key", label: "API key"}
    ]
  }

  @slow_echo %Manifest{
    id: "slow_echo",
    name: "Slow Echo (dev)",
    version: "0.1.0",
    category: :model,
    credential_schema: []
  }

  @drip %Manifest{
    id: "drip",
    name: "Drip (dev)",
    version: "0.1.0",
    category: :model,
    credential_schema: []
  }

  def list_plugins, do: [@echo, @openai, @slow_echo, @drip]
  def list_model_providers, do: [@echo, @openai, @slow_echo, @drip]

  def models("echo", _credentials), do: {:ok, [%Spec{name: "echo-1", label: "Echo v1"}]}
  def models("slow_echo", _credentials), do: {:ok, [%Spec{name: "echo-1", label: "Echo v1"}]}
  def models("drip", _credentials), do: {:ok, [%Spec{name: "echo-1", label: "Echo v1"}]}
  def models("openai", _credentials), do: {:ok, [%Spec{name: "gpt-4o", label: "GPT-4o"}]}
  def models(_other, _credentials), do: {:error, :unknown_plugin}

  def validate_credentials("echo", _), do: :ok
  def validate_credentials("slow_echo", _), do: :ok
  def validate_credentials("drip", _), do: :ok
  def validate_credentials("openai", %{"api_key" => "sk-valid"}), do: :ok
  def validate_credentials("openai", _), do: {:error, "Invalid API key."}
  def validate_credentials(_other, _), do: {:error, :unknown_plugin}

  def invoke_llm("echo", _credentials, request, emit) do
    last_user =
      request.messages
      |> Enum.reverse()
      |> Enum.find_value("(nothing)", fn
        %{role: :user, content: content} -> content
        _ -> nil
      end)

    reply = "You said: #{last_user}"

    for word <- String.split(reply, " ") do
      emit.(%Chunk{delta: word <> " "})
    end

    {:ok, %Result{content: reply <> " ", usage: %{input_tokens: 3, output_tokens: 12}}}
  end

  # Sleeps mid-invocation so tests can exercise stopping an in-flight run.
  def invoke_llm("slow_echo", credentials, request, emit) do
    Process.sleep(:timer.seconds(5))
    invoke_llm("echo", credentials, request, emit)
  end

  # Emits a prefix, then hangs — for testing that stop preserves streamed text.
  def invoke_llm("drip", _credentials, _request, emit) do
    emit.(%Chunk{delta: "Dripped "})
    emit.(%Chunk{delta: "prefix"})
    Process.sleep(:timer.seconds(5))
    {:ok, %Result{content: "never finished", usage: %{input_tokens: 1, output_tokens: 1}}}
  end

  def invoke_llm(_other, _credentials, _request, _emit), do: {:error, :unknown_plugin}
end
