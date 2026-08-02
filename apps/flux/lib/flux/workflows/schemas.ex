defmodule Flux.Workflows.Workflow do
  @moduledoc """
  A flux: a workflow whose editable draft lives in `graph` (the JSON shape
  `Flux.Engine.build/1` validates) and whose published snapshots live in
  `workflow_versions`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflows" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :created_by, Flux.Accounts.Account

    field :name, :string
    field :description, :string
    field :graph, :map, default: %{}
    field :site_token, :string
    field :site_enabled, :boolean, default: false
    field :site_theme, :map, default: %{}
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end
end

defmodule Flux.Workflows.WorkflowVersion do
  @moduledoc "An immutable published snapshot of a workflow's graph."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_versions" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :workflow, Flux.Workflows.Workflow
    belongs_to :published_by, Flux.Accounts.Account

    field :version, :integer
    field :graph, :map

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Workflows.WorkflowBatch do
  @moduledoc """
  A batch execution: one graph snapshot run once per input row. Counters
  advance as rows finish; `status` flips to `:completed` when the last
  row lands.
  """
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_batches" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :workflow, Flux.Workflows.Workflow

    field :name, :string
    field :status, Ecto.Enum, values: [:running, :completed], default: :running
    field :graph, :map
    field :rows, {:array, :map}, default: []
    field :total, :integer, default: 0
    field :succeeded, :integer, default: 0
    field :failed, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Workflows.WorkflowRun do
  @moduledoc """
  One execution of a workflow. `version` is nil for draft runs;
  `node_executions` holds the per-node trace written when the run ends.
  """
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_runs" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :workflow, Flux.Workflows.Workflow

    field :version, :integer

    field :status, Ecto.Enum,
      values: [:running, :succeeded, :failed, :stopped, :paused],
      default: :running

    field :source, Ecto.Enum, values: [:draft, :api, :batch, :eval], default: :draft
    belongs_to :batch, Flux.Workflows.WorkflowBatch
    field :inputs, :map, default: %{}
    field :outputs, :map, default: %{}
    field :error, :string
    field :node_executions, {:array, :map}, default: []
    field :elapsed_ms, :integer
    field :usage, :map, default: %{}
    field :snapshot, :map

    timestamps(type: :utc_datetime)
  end
end
