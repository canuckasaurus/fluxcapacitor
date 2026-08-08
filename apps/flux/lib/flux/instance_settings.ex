defmodule Flux.InstanceSettings do
  @moduledoc """
  Instance-wide key/value settings (not workspace-scoped): currently the
  status-page incident note. Tiny by design — one row per key.
  """

  import Ecto.Query

  alias Flux.Repo

  defmodule Setting do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key, :string, autogenerate: false}

    schema "instance_settings" do
      field :value, :string

      timestamps(type: :utc_datetime)
    end
  end

  def get(key, default \\ nil) do
    case Repo.get(Setting, key) do
      %Setting{value: value} -> value
      nil -> default
    end
  end

  def put(key, value) when is_binary(key) do
    case String.trim(to_string(value || "")) do
      "" ->
        Repo.delete_all(from(s in Setting, where: s.key == ^key))
        :ok

      value ->
        Repo.insert!(
          %Setting{key: key, value: value},
          on_conflict: {:replace, [:value, :updated_at]},
          conflict_target: :key
        )

        :ok
    end
  end
end
