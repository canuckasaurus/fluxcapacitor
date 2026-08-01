defmodule Flux.Plugin.Tool do
  @moduledoc """
  Behaviour for tool plugins: named operations with JSON-schema
  parameters, invocable from tool/agent nodes exactly like imported
  OpenAPI toolsets (they appear as `plugin:<id>` pseudo-toolsets once
  installed in a workspace).
  """

  defmodule Operation do
    @moduledoc "One callable operation of a tool plugin."
    @enforce_keys [:id, :name]
    defstruct [:id, :name, description: "", parameters: %{"type" => "object", "properties" => %{}}]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            description: String.t(),
            parameters: map()
          }
  end

  @type credentials :: %{optional(String.t()) => String.t()}
  @type result :: %{text: String.t(), data: term()}

  @callback operations(credentials) :: [Operation.t()]
  @callback invoke(credentials, operation_id :: String.t(), args :: map()) ::
              {:ok, result()} | {:error, term()}
end
