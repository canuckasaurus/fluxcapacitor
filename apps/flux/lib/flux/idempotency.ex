defmodule Flux.Idempotency do
  @moduledoc """
  Stored responses for `Idempotency-Key`-bearing `/v1` POSTs: a client
  retry with the same key replays the recorded JSON response instead of
  running the work twice. Keys are per workspace, kept 24 hours (the
  minute-tick scheduler prunes), and only successful buffered JSON
  responses are recorded — SSE streams can't be replayed and aren't.

  Reservation happens *before* the work runs: `reserve/2` atomically
  claims the (workspace_id, key) pair via a unique index, so two
  concurrent first-requests with the same key can't both miss the
  lookup and both run the work. The loser gets `:in_progress` instead.
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

  @doc """
  Atomically claims (workspace_id, key) for this request:

    * `{:reserved, id}` — this caller won the race; do the work, then
      call `complete/3` (success) or `release/1` (nothing to cache).
    * `{:completed, status, body}` — a prior request already finished
      under this key; replay its response.
    * `:in_progress` — another request is working on this key right
      now; the caller should refuse rather than run the work twice.
  """
  def reserve(workspace_id, key) when is_binary(key) do
    {count, _} =
      Repo.insert_all(
        Key,
        [
          %{
            id: UUIDv7.generate(),
            workspace_id: workspace_id,
            key: String.slice(key, 0, 255),
            inserted_at: DateTime.utc_now(:second)
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:workspace_id, :key]
      )

    case count do
      1 ->
        %Key{id: id} = lookup(workspace_id, key)
        {:reserved, id}

      0 ->
        case lookup(workspace_id, key) do
          %Key{response_status: nil} -> :in_progress
          %Key{response_status: status, response_body: body} -> {:completed, status, body}
          nil -> :in_progress
        end
    end
  end

  @doc "Records the finished response against an earlier reservation."
  def complete(id, status, body) when is_integer(status) and is_binary(body) do
    from(k in Key, where: k.id == ^id)
    |> Repo.update_all(
      [set: [response_status: status, response_body: body]],
      skip_workspace_guard: true
    )

    :ok
  end

  @doc "Releases a reservation with nothing worth caching (error, SSE stream)."
  def release(id) do
    from(k in Key, where: k.id == ^id and is_nil(k.response_status))
    |> Repo.delete_all(skip_workspace_guard: true)

    :ok
  end

  @doc """
  Drops completed keys older than a day (replay protection, not an
  archive) and reservations abandoned mid-request (crashed before
  `complete/3` or `release/1` ran) after 2 minutes, so a dropped
  connection doesn't wedge a key in `:in_progress` for the full day.
  """
  def prune(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -1, :day)
    stuck_cutoff = DateTime.add(now, -2, :minute)

    from(k in Key, where: k.inserted_at < ^cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    from(k in Key, where: is_nil(k.response_status) and k.inserted_at < ^stuck_cutoff)
    |> Repo.delete_all(skip_workspace_guard: true)

    :ok
  end
end
