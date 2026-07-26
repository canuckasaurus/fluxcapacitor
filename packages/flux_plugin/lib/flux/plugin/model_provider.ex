defmodule Flux.Plugin.ModelProvider do
  @moduledoc """
  Behaviour for model-provider plugins (the BEAM-native replacement for
  Dify's daemon-hosted provider plugins).

  Streaming is push-based: `invoke_llm/3` receives an `emit` function and
  calls it with `%Chunk{}`s as tokens arrive, then returns the final
  `%Result{}`. The host owns delivery (PubSub, SSE); plugins never see
  transport.
  """

  defmodule Spec do
    @moduledoc "A model offered by the provider."
    @enforce_keys [:name, :label]
    defstruct [:name, :label, type: :llm, context_window: nil, features: []]

    @type t :: %__MODULE__{
            name: String.t(),
            label: String.t(),
            type: :llm | :text_embedding | :rerank,
            context_window: pos_integer() | nil,
            features: [atom()]
          }
  end

  defmodule Request do
    @moduledoc "An LLM invocation."
    @enforce_keys [:model, :messages]
    defstruct [:model, :messages, params: %{}, stream: true]

    @type message :: %{role: :system | :user | :assistant, content: String.t()}
    @type t :: %__MODULE__{
            model: String.t(),
            messages: [message()],
            params: %{optional(atom()) => term()},
            stream: boolean()
          }
  end

  defmodule Chunk do
    @moduledoc "A streamed delta."
    defstruct delta: ""
    @type t :: %__MODULE__{delta: String.t()}
  end

  defmodule Result do
    @moduledoc "The final result of an invocation."
    defstruct content: "", finish_reason: :stop, usage: %{input_tokens: 0, output_tokens: 0}

    @type t :: %__MODULE__{
            content: String.t(),
            finish_reason: :stop | :length | :error,
            usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
          }
  end

  @type credentials :: %{optional(String.t()) => String.t()}
  @type emit :: (Chunk.t() -> :ok)

  @callback models(credentials) :: [Spec.t()]
  @callback validate_credentials(credentials) :: :ok | {:error, String.t()}
  @callback invoke_llm(credentials, Request.t(), emit) :: {:ok, Result.t()} | {:error, term()}
end
