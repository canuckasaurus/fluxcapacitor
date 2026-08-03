defmodule Flux.Notifications do
  @moduledoc """
  In-console notifications: run failures, gate blocks, eval regressions,
  and labeling-project completions land in a workspace feed with an
  unread badge in the sidebar — the events that previously only reached
  webhooks. Workspace-wide by design (one feed per workspace, read state
  shared): the console is a team surface, and per-member read tracking
  isn't worth a join table yet.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Repo

  defmodule Notification do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "notifications" do
      belongs_to :workspace, Flux.Accounts.Workspace

      field :kind, :string
      field :title, :string
      field :path, :string
      field :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end

  @kinds ~w(run_failed gate_blocked eval_regressed labeling_completed export_ready
            budget_warning)

  @doc """
  Records a notification (worker-safe: takes a workspace id, no scope).
  `path` is a console link ("/console/runs"). Unknown kinds are refused
  so the feed stays enumerable.
  """
  def notify(workspace_id, kind, title, path \\ nil) when kind in @kinds do
    Repo.insert!(%Notification{
      workspace_id: workspace_id,
      kind: kind,
      title: String.slice(to_string(title), 0, 255),
      path: path
    })

    Phoenix.PubSub.broadcast(Flux.PubSub, topic(workspace_id), :notifications_changed)
    :ok
  end

  def list(%Scope{} = scope, limit \\ 30) do
    Notification
    |> Repo.scoped(scope)
    |> order_by([n], desc: n.inserted_at, desc: n.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def unread_count(%Scope{} = scope) do
    Notification
    |> Repo.scoped(scope)
    |> where([n], is_nil(n.read_at))
    |> Repo.aggregate(:count)
  end

  def mark_all_read(%Scope{} = scope) do
    Notification
    |> Repo.scoped(scope)
    |> where([n], is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    :ok
  end

  def topic(workspace_id), do: "notifications:#{workspace_id}"

  def subscribe(workspace_id),
    do: Phoenix.PubSub.subscribe(Flux.PubSub, topic(workspace_id))
end
