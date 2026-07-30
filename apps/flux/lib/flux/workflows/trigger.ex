defmodule Flux.Workflows.Trigger do
  @moduledoc """
  Starts published runs from the outside: `:webhook` (POST
  /triggers/webhook/:token) or `:schedule` (every `interval_minutes`,
  driven by `Flux.Workflows.ScheduleWorker`). `inputs` are the static
  start-variables for triggered runs; webhook payloads override them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_triggers" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :workflow, Flux.Workflows.Workflow

    field :type, Ecto.Enum, values: [:webhook, :schedule]
    field :token, :string
    field :interval_minutes, :integer
    field :inputs, :map, default: %{}
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :interval_minutes, :inputs, :enabled])
    |> validate_required([:type])
    |> validate_number(:interval_minutes, greater_than_or_equal_to: 1)
    |> then(fn changeset ->
      case get_field(changeset, :type) do
        :schedule -> validate_required(changeset, [:interval_minutes])
        _webhook -> changeset
      end
    end)
  end
end
