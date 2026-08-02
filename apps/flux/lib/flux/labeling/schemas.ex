defmodule Flux.Labeling.Project do
  @moduledoc """
  A labeling project: a label schema plus a queue of tasks. `label_type`
  decides the tagging UI — `:choice` (one option), `:multi` (several),
  or `:text` (free-text answer/correction).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "labeling_projects" do
    belongs_to :workspace, Flux.Accounts.Workspace

    field :name, :string
    field :label_type, Ecto.Enum, values: [:choice, :multi, :text], default: :choice
    field :options, {:array, :string}, default: []
    field :instructions, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :label_type, :options, :instructions])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> update_change(:options, fn options ->
      options |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    end)
    |> validate_options()
  end

  # Not validate_length/3: that only fires when :options is in the
  # changes, and an omitted field must still fail for choice types.
  defp validate_options(changeset) do
    options = get_field(changeset, :options) || []

    case get_field(changeset, :label_type) do
      :text ->
        changeset

      _choices when length(options) >= 2 ->
        changeset

      _choices ->
        add_error(changeset, :options, "needs at least two options for choice labeling")
    end
  end
end

defmodule Flux.Labeling.Task do
  @moduledoc "One item awaiting (or holding) a human label."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "labeling_tasks" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :project, Flux.Labeling.Project
    belongs_to :labeled_by, Flux.Accounts.Account

    field :data, :map, default: %{}
    field :status, Ecto.Enum, values: [:unlabeled, :labeled, :skipped], default: :unlabeled
    field :label, :map
    field :source, :string

    timestamps(type: :utc_datetime)
  end
end
