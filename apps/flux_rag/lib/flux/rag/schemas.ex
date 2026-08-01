defmodule Flux.RAG.Dataset do
  @moduledoc "A knowledge base: documents split into embedded segments."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "datasets" do
    belongs_to(:workspace, Flux.Accounts.Workspace)

    field(:name, :string)
    field(:description, :string)
    field(:embedding_plugin_id, :string)
    field(:embedding_model, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(dataset, attrs) do
    dataset
    |> cast(attrs, [:name, :description, :embedding_plugin_id, :embedding_model])
    |> validate_required([:name, :embedding_plugin_id, :embedding_model])
    |> validate_length(:name, min: 1, max: 255)
  end
end

defmodule Flux.RAG.Document do
  @moduledoc "One ingested document; segments carry the indexed text."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_documents" do
    belongs_to(:workspace, Flux.Accounts.Workspace)
    belongs_to(:dataset, Flux.RAG.Dataset)

    field(:name, :string)
    field(:status, Ecto.Enum, values: [:pending, :indexing, :ready, :error], default: :pending)
    field(:error, :string)
    field(:segment_count, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.RAG.Segment do
  @moduledoc "A chunk of a document with its embedding vector."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_segments" do
    belongs_to(:workspace, Flux.Accounts.Workspace)
    belongs_to(:dataset, Flux.RAG.Dataset)
    belongs_to(:document, Flux.RAG.Document)

    field(:position, :integer)
    field(:content, :string)
    field(:embedding, {:array, :float})

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
