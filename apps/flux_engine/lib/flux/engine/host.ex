defmodule Flux.Engine.Host do
  @moduledoc """
  Capabilities the embedding application injects into a run.

  The engine is a pure library: it never touches the database, PubSub, or a
  model provider directly. `Flux.Workflows` builds a host whose `invoke_llm`
  closes over the workspace's credentials and whose `emit` broadcasts engine
  events to subscribers.
  """

  defstruct emit: nil,
            invoke_llm: nil,
            invoke_tool: nil,
            http_request: nil,
            run_code: nil,
            read_document: nil,
            run_subflux: nil,
            retrieve_knowledge: nil,
            fetch_doc_template: nil,
            fetch_docx_template: nil,
            store_file: nil,
            fetch_interview: nil,
            default_llm: nil

  @typedoc """
  `invoke_llm` receives `%{provider_plugin_id, model, messages, params}`
  (messages as `%{role: :system | :user | :assistant, content: binary}`) and
  a chunk callback; it returns `{:ok, %{content: binary, usage: map}}` or
  `{:error, term}`.

  `invoke_tool` receives `%{toolset_id, operation_id, args}` and returns
  `{:ok, %{status: integer, body: term, text: binary}}` or `{:error, term}`.
  """
  @type t :: %__MODULE__{
          emit: (term() -> any()) | nil,
          invoke_llm: (map(), (String.t() -> any()) -> {:ok, map()} | {:error, term()}) | nil,
          invoke_tool: (map() -> {:ok, map()} | {:error, term()}) | nil,
          http_request: (map() -> {:ok, map()} | {:error, term()}) | nil,
          run_code: (map() -> {:ok, map()} | {:error, term()}) | nil,
          read_document: (map() -> {:ok, map()} | {:error, term()}) | nil,
          run_subflux: (map() -> {:ok, map()} | {:error, term()}) | nil,
          retrieve_knowledge: (map() -> {:ok, [map()]} | {:error, term()}) | nil,
          fetch_doc_template: (String.t() -> {:ok, String.t()} | {:error, term()}) | nil,
          fetch_docx_template: (String.t() -> {:ok, map()} | {:error, term()}) | nil,
          store_file: (map() -> {:ok, map()} | {:error, term()}) | nil,
          fetch_interview: (String.t() -> {:ok, map()} | {:error, term()}) | nil,
          default_llm: %{optional(String.t()) => String.t()} | nil
        }

  @doc """
  Resolves a node's provider/model pair, falling back to the host's
  workspace default (`default_llm: %{"provider_plugin_id", "model"}`)
  when the node config names none.
  """
  def resolve_llm(%__MODULE__{} = host, config) do
    plugin_id = to_string(config["provider_plugin_id"] || "")
    model = to_string(config["model"] || "")

    case {plugin_id, model, host.default_llm} do
      {"", "", %{"provider_plugin_id" => default_plugin, "model" => default_model}} ->
        {to_string(default_plugin), to_string(default_model)}

      _explicit_or_no_default ->
        {plugin_id, model}
    end
  end

  @doc false
  def emit(%__MODULE__{emit: nil}, _event), do: :ok

  def emit(%__MODULE__{emit: emit}, event) do
    emit.(event)
    :ok
  end
end
