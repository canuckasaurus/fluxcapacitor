defmodule Flux.Evals.EvalSet do
  @moduledoc "A named collection of test cases for one flux."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "eval_sets" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :workflow, Flux.Workflows.Workflow

    field :name, :string
    field :gate, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(set, attrs) do
    set
    |> cast(attrs, [:name, :gate])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end
end

defmodule Flux.Evals.EvalCase do
  @moduledoc "One test case: start inputs plus the expected/reference answer."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "eval_cases" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :eval_set, Flux.Evals.EvalSet

    field :inputs, :map, default: %{}
    field :expected, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(eval_case, attrs) do
    eval_case
    |> cast(attrs, [:inputs, :expected])
    |> validate_required([:expected])
  end
end

defmodule Flux.Evals.EvalRun do
  @moduledoc """
  One scoring pass: a graph snapshot (draft or a published version) run
  over every case in the set and graded. `results` holds one map per
  case: inputs, output, score (0..1), verdict, and the grader's reason.
  """
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "eval_runs" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :eval_set, Flux.Evals.EvalSet
    belongs_to :workflow, Flux.Workflows.Workflow

    field :target, :string
    field :grader, :string
    field :judge, :string
    field :status, Ecto.Enum, values: [:running, :completed], default: :running
    field :graph, :map
    field :total, :integer, default: 0
    field :passed, :integer, default: 0
    field :failed, :integer, default: 0
    field :avg_score, :float
    field :results, {:array, :map}, default: []

    timestamps(type: :utc_datetime)
  end
end
