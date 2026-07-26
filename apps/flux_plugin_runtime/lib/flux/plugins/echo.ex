defmodule Flux.Plugins.Echo do
  @moduledoc """
  Development/test model provider: streams the last user message back word
  by word. Lets the whole chat pipeline run end-to-end with no API keys.
  """
  @behaviour Flux.Plugin
  @behaviour Flux.Plugin.ModelProvider

  alias Flux.Plugin.Manifest
  alias Flux.Plugin.ModelProvider.{Chunk, Result, Spec}

  @impl Flux.Plugin
  def manifest do
    %Manifest{
      id: "echo",
      name: "Echo (dev)",
      version: "0.1.0",
      category: :model,
      description: "Streams your message back. For development and demos — no API key needed.",
      credential_schema: []
    }
  end

  @impl Flux.Plugin.ModelProvider
  def models(_credentials), do: [%Spec{name: "echo-1", label: "Echo v1"}]

  @impl Flux.Plugin.ModelProvider
  def validate_credentials(_credentials), do: :ok

  @impl Flux.Plugin.ModelProvider
  def invoke_llm(_credentials, request, emit) do
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
      Process.sleep(10)
    end

    {:ok,
     %Result{
       content: reply <> " ",
       finish_reason: :stop,
       usage: %{input_tokens: div(byte_size(last_user), 4), output_tokens: 12}
     }}
  end
end
