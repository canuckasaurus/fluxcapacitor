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
    field(:split_markdown, :boolean, default: false)
    field(:parent_child, :boolean, default: false)
    field(:query_expansion, :boolean, default: false)
    # How retrieve/4 ranks: :hybrid fuses semantic + keyword + entity
    # rankings (RRF); the single-source modes skip the others entirely.
    field(:retrieval_mode, Ecto.Enum, values: [:hybrid, :semantic, :keyword], default: :hybrid)
    # Hybrid only: skews RRF contributions toward semantic (→1.0) or
    # keyword/entity (→0.0). nil or 0.5 is the neutral fusion.
    field(:semantic_weight, :float)
    field(:rerank_plugin_id, :string)
    field(:rerank_model, :string)
    field(:sync_plugin_id, :string)
    field(:sync_interval_minutes, :integer)
    field(:last_synced_at, :utc_datetime)
    field(:retrieval_top_k, :integer)
    field(:score_threshold, :float)
    field(:entity_plugin_id, :string)
    field(:entity_model, :string)
    # Scheduled retrieval evals: cron + the last run's scores, so a
    # regression is detectable (and notifiable) without a human diff.
    field(:retrieval_eval_cron, :string)
    field(:last_retrieval_hit_rate, :float)
    field(:last_retrieval_mrr, :float)
    field(:last_retrieval_eval_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)

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
      :split_markdown,
      :parent_child,
      :query_expansion,
      :retrieval_mode,
      :semantic_weight,
      :rerank_plugin_id,
      :rerank_model,
      :sync_plugin_id,
      :sync_interval_minutes,
      :retrieval_top_k,
      :score_threshold,
      :entity_plugin_id,
      :entity_model,
      :retrieval_eval_cron
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
    |> validate_number(:semantic_weight,
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
    |> validate_retrieval_cron()
  end

  # Same parser as schedule triggers and eval sets: anything Oban's cron
  # accepts. Blank clears the schedule.
  defp validate_retrieval_cron(changeset) do
    case get_change(changeset, :retrieval_eval_cron) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :retrieval_eval_cron, nil)

      cron ->
        case Oban.Cron.Expression.parse(cron) do
          {:ok, _expression} ->
            changeset

          {:error, _reason} ->
            add_error(changeset, :retrieval_eval_cron, "is not a valid cron expression")
        end
    end
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
    # Disabled documents keep their segments but retrieval skips them
    # (the flag cascades to segments' enabled).
    field(:enabled, :boolean, default: true)
    field(:error, :string)
    field(:segment_count, :integer, default: 0)
    field(:content, :string)
    field(:tags, {:array, :string}, default: [])
    # Typed key-values ("region" => "EU") — retrieval filters on these.
    field(:metadata, :map, default: %{})

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
    # Parent-child datasets index small child chunks for precision but
    # hand retrieval the enclosing parent section for context.
    field(:parent_content, :string)
    field(:embedding, {:array, :float})
    field(:enabled, :boolean, default: true)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

defmodule Flux.RAG.Entity do
  @moduledoc "A named thing mentioned in a dataset (GraphRAG groundwork)."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_entities" do
    belongs_to(:workspace, Flux.Accounts.Workspace)
    belongs_to(:dataset, Flux.RAG.Dataset)
    field(:name, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

defmodule Flux.RAG.EntityMention do
  @moduledoc "Links an entity to a segment that mentions it."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_entity_mentions" do
    belongs_to(:workspace, Flux.Accounts.Workspace)
    belongs_to(:dataset, Flux.RAG.Dataset)
    belongs_to(:entity, Flux.RAG.Entity)
    belongs_to(:segment, Flux.RAG.Segment)
  end
end

defmodule Flux.RAG.UrlSource do
  @moduledoc """
  A remembered URL source: re-fetched nightly so the dataset tracks the
  page (or, with `crawl`, the page and its same-site links).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "dataset_url_sources" do
    belongs_to(:workspace, Flux.Accounts.Workspace)
    belongs_to(:dataset, Flux.RAG.Dataset)

    field(:url, :string)
    field(:crawl, :boolean, default: false)
    field(:last_fetched_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:url, :crawl])
    |> validate_required([:url])
    |> unique_constraint([:dataset_id, :url])
  end
end

defmodule Flux.RAG.RetrievalCase do
  @moduledoc """
  A golden retrieval case: for `question`, a passage containing
  `expected` should come back. Scored by hit rate and MRR — the signal
  that a chunking/backend change helped or hurt retrieval itself.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "retrieval_cases" do
    belongs_to(:workspace, Flux.Accounts.Workspace)
    belongs_to(:dataset, Flux.RAG.Dataset)

    field(:question, :string)
    field(:expected, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(retrieval_case, attrs) do
    retrieval_case
    |> cast(attrs, [:question, :expected])
    |> validate_required([:question, :expected])
    |> validate_length(:question, min: 1, max: 500)
    |> validate_length(:expected, min: 1, max: 500)
  end
end
