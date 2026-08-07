defmodule Flux.Plugin.ModelProvider do
  @moduledoc """
  Behaviour for model-provider plugins (the BEAM-native replacement for
  daemon-hosted provider plugins elsewhere).

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

  defmodule ToolDef do
    @moduledoc "A callable tool offered to the model (JSON-schema parameters)."
    @enforce_keys [:name]
    defstruct [:name, description: "", parameters: %{"type" => "object", "properties" => %{}}]

    @type t :: %__MODULE__{name: String.t(), description: String.t(), parameters: map()}
  end

  defmodule ToolCall do
    @moduledoc "A tool invocation the model requested."
    @enforce_keys [:id, :name]
    defstruct [:id, :name, arguments: %{}]

    @type t :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}
  end

  defmodule Request do
    @moduledoc """
    An LLM invocation. Messages may be plain (`%{role, content}`),
    assistant turns carrying `tool_calls`, or tool results
    (`%{role: :tool, tool_call_id, name, content}`).
    """
    @enforce_keys [:model, :messages]
    defstruct [:model, :messages, params: %{}, stream: true, tools: []]

    @type message :: %{
            optional(:tool_calls) => [ToolCall.t()],
            optional(:tool_call_id) => String.t(),
            optional(:name) => String.t(),
            role: :system | :user | :assistant | :tool,
            content: String.t() | nil
          }
    @type t :: %__MODULE__{
            model: String.t(),
            messages: [message()],
            params: %{optional(atom()) => term()},
            stream: boolean(),
            tools: [ToolDef.t()]
          }
  end

  defmodule Chunk do
    @moduledoc "A streamed delta."
    defstruct delta: ""
    @type t :: %__MODULE__{delta: String.t()}
  end

  defmodule Result do
    @moduledoc "The final result of an invocation."
    defstruct content: "",
              finish_reason: :stop,
              usage: %{input_tokens: 0, output_tokens: 0},
              tool_calls: []

    @type t :: %__MODULE__{
            content: String.t(),
            finish_reason: :stop | :length | :tool_calls | :error,
            usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
            tool_calls: [ToolCall.t()]
          }
  end

  @type credentials :: %{optional(String.t()) => String.t()}
  @type emit :: (Chunk.t() -> :ok)
  @type embeddings :: %{vectors: [[float()]], usage: %{input_tokens: non_neg_integer()}}

  @callback models(credentials) :: [Spec.t()]
  @callback validate_credentials(credentials) :: :ok | {:error, String.t()}
  @callback invoke_llm(credentials, Request.t(), emit) :: {:ok, Result.t()} | {:error, term()}
  @callback invoke_embeddings(credentials, model :: String.t(), texts :: [String.t()]) ::
              {:ok, embeddings()} | {:error, term()}

  @callback invoke_rerank(
              credentials,
              model :: String.t(),
              query :: String.t(),
              documents :: [String.t()]
            ) :: {:ok, [%{index: non_neg_integer(), score: float()}]} | {:error, term()}

  @doc """
  Speech-to-text. `opts` may carry `:model` (defaults to the provider's
  standard transcription model), `:filename`, and `:content_type`.
  """
  @callback invoke_transcription(credentials, audio :: binary(), opts :: map()) ::
              {:ok, %{text: String.t()}} | {:error, term()}

  @doc """
  Text-to-speech. `opts` may carry `:model` and `:voice`. Returns the
  audio bytes with their content type.
  """
  @callback invoke_speech(credentials, text :: String.t(), opts :: map()) ::
              {:ok, %{audio: binary(), content_type: String.t()}} | {:error, term()}

  @optional_callbacks invoke_embeddings: 3,
                      invoke_rerank: 4,
                      invoke_transcription: 3,
                      invoke_speech: 3
end
