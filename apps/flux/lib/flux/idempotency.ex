defmodule Flux.Idempotency do
  @moduledoc """
  Stored responses for `Idempotency-Key`-bearing `/v1` POSTs: a client
  retry with the same key replays the recorded JSON response instead of
  running the work twice. Keys are per workspace, kept 24 hours (the
  nightly scheduler prunes), and only successful buffered JSON responses
  are recorded — SSE streams can't be replayed and aren't.
  """

  import Ecto.Query

  alias Flux.Repo

  defmodule Key do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "idempotency_keys" do
      belongs_to :workspace, Flux.Accounts.Workspace

      field :key, :string
      field :response_status, :integer
      field :response_body, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end

  @doc "The stored response for this workspace + key, or nil."
  def lookup(workspace_id, key) when is_binary(key) do
    Repo.one(from(k in Key, where: k.workspace_id == ^workspace_id and k.key == ^key))
  end

  @doc "Records a response; a concurrent duplicate quietly loses."
  def record(workspace_id, key, status, body)
      when is_binary(key) and is_integer(status) and is_binary(body) do
    %Key{
      workspace_id: workspace_id,
      key: String.slice(key, 0, 255),
      response_status: status,
      response_body: body
    }
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:workspace_id, :key])

    :ok
  end

  @doc "Drops keys older than a day — replay protection, not an archive."
  def prune(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -1, :day)

    from(k in Key, where: k.inserted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    :ok
  end
end
