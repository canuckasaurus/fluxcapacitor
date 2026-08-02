defmodule Flux.Webhooks.Endpoint do
  @moduledoc """
  A workspace's outgoing-webhook registration. The signing secret is
  minted server-side on create and never accepted from params.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webhook_endpoints" do
    belongs_to :workspace, Flux.Accounts.Workspace

    field :url, :string
    field :secret, :string, redact: true
    field :events, {:array, :string}, default: []
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :events, :enabled])
    |> validate_required([:url])
    |> validate_length(:url, max: 2048)
    |> validate_url()
    |> validate_events()
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _invalid ->
          [url: "must be an http(s) URL"]
      end
    end)
  end

  defp validate_events(changeset) do
    valid = ["*" | Flux.Webhooks.events()]

    changeset
    |> update_change(:events, &Enum.uniq/1)
    |> validate_change(:events, fn :events, events ->
      case Enum.reject(events, &(&1 in valid)) do
        [] -> []
        unknown -> [events: "unknown events: #{Enum.join(unknown, ", ")}"]
      end
    end)
    |> then(fn changeset ->
      case get_field(changeset, :events) do
        [] -> put_change(changeset, :events, ["run.succeeded", "run.failed"])
        _some -> changeset
      end
    end)
  end
end
