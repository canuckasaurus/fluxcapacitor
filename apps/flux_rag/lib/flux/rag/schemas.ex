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
    field(:chunk_size, :integer, default: 1000)
    field(:chunk_overlap, :integer, default: 120)
    field(:rerank_plugin_id, :string)
    field(:rerank_model, :string)
    field(:sync_plugin_id, :string)
    field(:sync_interval_minutes, :integer)
    field(:last_synced_at, :utc_datetime)
    field(:retrieval_top_k, :integer)
    field(:score_threshold, :float)

    timestamps(type: :utc_datetime)
  end

  def changeset(dataset, attrs) do
    dataset
    |> cast(attrs, [
      :name,
      :description,
      :embedding_plugin_id,
      :embedding_model,
      :chunk_size,
      :chunk_overlap,
      :rerank_plugin_id,
      :rerank_model,
      :sync_plugin_id,
      :sync_interval_minutes,
      :retrieval_top_k,
      :score_threshold
    ])
    |> validate_required([:name, :embedding_plugin_id, :embedding_model])
    |> validate_number(:chunk_size, greater_than_or_equal_to: 200, less_than_or_equal_to: 4000)
    |> validate_number(:chunk_overlap, greater_than_or_equal_to: 0, less_than_or_equal_to: 500)
    |> validate_number(:sync_interval_minutes, greater_than_or_equal_to: 5)
    |> validate_number(:retrieval_top_k, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
    |> validate_number(:score_threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_length(:name, min: 1, max: 255)
    |> then(fn changeset ->
      # Clearing the plugin clears the schedule with it.
      case get_field(changeset, :sync_plugin_id) do
        empty when empty in [nil, ""] ->
          change(changeset, sync_plugin_id: nil, sync_interval_minutes: nil)

        _plugin ->
          changeset
      end
    end)
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
    field(:content, :string)

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
    field(:enabled, :boolean, default: true)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
