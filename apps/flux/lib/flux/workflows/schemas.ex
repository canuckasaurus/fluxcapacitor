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
    # Named sample inputs for the editor's run panel.
    field :input_presets, :map, default: %{}
    # Freezes serving to this published version (nil = latest); wins
    # over the A/B split so pinning is an honest rollback lever.
    field :pinned_version, :integer
    # One whole-run retry on failure (transient provider errors).
    field :auto_retry, :boolean, default: false
    field :site_token, :string
    field :site_enabled, :boolean, default: false
    field :site_theme, :map, default: %{}
    field :deleted_at, :utc_datetime
    field :ab_version_b, :integer
    field :ab_split, :integer, default: 0
    # Optional per-flux monthly token cap (workspace budget still applies).
    field :monthly_token_budget, :integer
    field :budget_warned_month, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :monthly_token_budget, :auto_retry])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:monthly_token_budget, greater_than: 0)
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
    field :note, :string

    field :version, :integer
    field :graph, :map

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Workflows.WorkspaceTemplate do
  @moduledoc """
  A workspace-owned flux template: any flux saved as a starting point,
  listed in the gallery next to the built-ins so teams standardize their
  own patterns.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_templates" do
    belongs_to :workspace, Flux.Accounts.Workspace

    field :name, :string
    field :description, :string
    field :graph, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end
end

defmodule Flux.Workflows.BatchSchedule do
  @moduledoc """
  A recurring batch: a saved row set re-executed on a cron schedule
  against the draft or a pinned published version — nightly
  re-processing without re-uploading the CSV.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "batch_schedules" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :workflow, Flux.Workflows.Workflow

    field :name, :string
    field :rows, {:array, :map}, default: []
    field :cron, :string
    field :target, :string, default: "draft"
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :rows, :cron, :target, :enabled])
    |> validate_required([:name, :cron])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:rows, min: 1)
    |> validate_cron()
  end

  # Oban's parser, same as schedule triggers and eval schedules.
  defp validate_cron(changeset) do
    case get_change(changeset, :cron) do
      nil ->
        changeset

      cron ->
        case Oban.Cron.Expression.parse(cron) do
          {:ok, _expression} -> changeset
          {:error, _reason} -> add_error(changeset, :cron, "is not a valid cron expression")
        end
    end
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
    field :target, :string, default: "draft"
    # Rows in flight at once (1 = sequential, capped in start_batch).
    field :concurrency, :integer, default: 1
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
    # Set when this run is the automatic second attempt after a failure.
    belongs_to :retry_of, Flux.Workflows.WorkflowRun
    field :inputs, :map, default: %{}
    field :outputs, :map, default: %{}
    field :error, :string
    # Free-form labels for filtering run history (manual or API-set).
    field :tags, {:array, :string}, default: []
    field :node_executions, {:array, :map}, default: []
    field :elapsed_ms, :integer
    field :usage, :map, default: %{}
    field :snapshot, :map

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Workflows.RunComment do
  @moduledoc "A team note pinned to one workflow run (debugging context, verdicts)."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "run_comments" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :run, Flux.Workflows.WorkflowRun
    belongs_to :account, Flux.Accounts.Account

    field :body, :string

    timestamps(type: :utc_datetime)
  end
end
