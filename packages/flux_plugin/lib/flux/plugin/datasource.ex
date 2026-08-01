defmodule Flux.Plugin.Datasource do
  @moduledoc """
  Behaviour for datasource plugins: external document collections (feeds,
  wikis, drives) that sync into knowledge datasets. `list_documents/1`
  enumerates what the source currently offers; `fetch_document/2` returns
  one document's text for indexing.
  """

  defmodule SourceDoc do
    @moduledoc "One document offered by a datasource."
    @enforce_keys [:id, :name]
    defstruct [:id, :name, metadata: %{}]

    @type t :: %__MODULE__{id: String.t(), name: String.t(), metadata: map()}
  end

  @type credentials :: %{optional(String.t()) => String.t()}

  @callback list_documents(credentials) :: {:ok, [SourceDoc.t()]} | {:error, term()}
  @callback fetch_document(credentials, doc_id :: String.t()) ::
              {:ok, %{name: String.t(), content: String.t()}} | {:error, term()}
end
