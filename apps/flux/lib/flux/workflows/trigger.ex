defmodule Flux.Workflows.Trigger do
  @moduledoc """
  Starts published runs from the outside: `:webhook` (POST
  /triggers/webhook/:token), `:schedule` (every `interval_minutes` or a
  cron expression), or `:plugin` (an installed trigger plugin polled
  every `interval_minutes`; each event it returns becomes one run). All
  scheduled/polled types are driven by `Flux.Workflows.ScheduleWorker`.
  `inputs` are the static start-variables for triggered runs; webhook
  payloads and plugin events override them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_triggers" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :workflow, Flux.Workflows.Workflow

    field :type, Ecto.Enum, values: [:webhook, :schedule, :plugin]
    field :token, :string
    field :interval_minutes, :integer
    field :cron, :string
    field :plugin_id, :string
    field :plugin_cursor, :string
    field :webhook_secret, :string, redact: true
    field :inputs, :map, default: %{}
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :type,
      :interval_minutes,
      :cron,
      :inputs,
      :enabled,
      :plugin_id,
      :webhook_secret
    ])
    |> validate_required([:type])
    |> validate_number(:interval_minutes, greater_than_or_equal_to: 1)
    |> update_change(:cron, fn cron ->
      case String.trim(to_string(cron)) do
        "" -> nil
        trimmed -> trimmed
      end
    end)
    |> validate_cron()
    |> then(fn changeset ->
      case get_field(changeset, :type) do
        :schedule ->
          if get_field(changeset, :cron) do
            changeset
          else
            validate_required(changeset, [:interval_minutes])
          end

        :plugin ->
          validate_required(changeset, [:plugin_id, :interval_minutes])

        _webhook ->
          changeset
      end
    end)
  end

  # Cron expressions are parsed by Oban's own parser, so anything Oban's
  # cron plugin accepts works here too (5-field syntax, names, steps).
  defp validate_cron(changeset) do
    validate_change(changeset, :cron, fn :cron, cron ->
      case Oban.Cron.Expression.parse(cron) do
        {:ok, _expression} -> []
        {:error, error} -> [cron: "invalid cron expression: #{Exception.message(error)}"]
      end
    end)
  end
end
