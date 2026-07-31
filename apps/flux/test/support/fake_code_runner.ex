defmodule Flux.FakeCodeRunner do
  @moduledoc "Test double for Flux.CodeRunner: echoes inputs deterministically."
  @behaviour Flux.CodeRunner

  @impl true
  def run(%{code: "boom" <> _rest}), do: {:error, "exit 1: boom"}

  def run(spec) do
    {:ok,
     %{
       result: %{
         "echo" => spec.inputs,
         "language" => spec.language,
         "deps" => length(spec.dependencies)
       },
       stdout: "fake-run ok\n"
     }}
  end
end
