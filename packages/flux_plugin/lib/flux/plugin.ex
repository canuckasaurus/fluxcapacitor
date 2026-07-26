defmodule Flux.Plugin do
  @moduledoc """
  The FluxCapacitor plugin contract. A plugin is an Elixir module (usually
  its own hex package) that returns a `Flux.Plugin.Manifest` and implements
  one or more capability behaviours (`Flux.Plugin.ModelProvider` today;
  Tool/Datasource/Trigger/AgentStrategy/Endpoint arrive with plugin GA).
  """

  alias Flux.Plugin.Manifest

  @callback manifest() :: Manifest.t()

  defmodule Manifest do
    @moduledoc "Static plugin metadata, validated at catalog load."

    @enforce_keys [:id, :name, :version, :category]
    defstruct [
      :id,
      :name,
      :version,
      :category,
      description: "",
      capabilities: [],
      credential_schema: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            version: String.t(),
            category: :model | :tool | :datasource | :trigger | :agent_strategy | :extension,
            description: String.t(),
            capabilities: [atom()],
            credential_schema: [Flux.Plugin.CredentialField.t()]
          }
  end

  defmodule CredentialField do
    @moduledoc "One field of a plugin's credential form."
    @enforce_keys [:key, :label]
    defstruct [:key, :label, type: :secret, required: true, placeholder: nil, help: nil]

    @type t :: %__MODULE__{
            key: String.t(),
            label: String.t(),
            type: :secret | :text | :url,
            required: boolean(),
            placeholder: String.t() | nil,
            help: String.t() | nil
          }
  end
end
