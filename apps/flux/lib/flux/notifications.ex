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
            budget_warning guardrail digest handoff cost_report api_key_expiring)

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

    # Routing: endpoints subscribe to `notification.<kind>` events, so
    # each webhook picks exactly the kinds it wants forwarded.
    Flux.Webhooks.dispatch(workspace_id, "notification." <> kind, %{
      "kind" => kind,
      "title" => to_string(title),
      "path" => path
    })

    # Members who opted into this kind get it by email too (best-effort,
    # in-band: callers are already async workers or spawned tasks).
    # Accounts inside their quiet hours get the email deferred to the
    # window's end via a scheduled Oban job instead of a 3am ping.
    now = DateTime.utc_now(:second)

    for account <- Flux.Accounts.accounts_subscribed_to(workspace_id, kind) do
      if Flux.Accounts.in_quiet_hours?(account, now.hour) do
        %{
          email: account.email,
          kind: kind,
          title: to_string(title),
          path: path,
          workspace_id: workspace_id
        }
        |> Flux.Notifications.EmailWorker.new(scheduled_at: quiet_end(account, now))
        |> Oban.insert()
      else
        Flux.Accounts.AccountNotifier.deliver_notification_email(
          account.email,
          kind,
          to_string(title),
          path,
          workspace_id
        )
      end
    end

    # Urgent kinds also reach subscribed browsers even when no console
    # tab is open; delivery rides Oban so a dead endpoint costs nothing.
    if kind in Flux.WebPush.push_kinds() do
      member_ids =
        for member <- Flux.Accounts.scim_list_members(workspace_id), do: member.account_id

      Flux.WebPush.fan_out(member_ids, to_string(title), path)
    end

    Phoenix.PubSub.broadcast(Flux.PubSub, topic(workspace_id), :notifications_changed)
    :ok
  end

  @doc "The webhook event names notifications can route to."
  def webhook_events, do: for(kind <- @kinds, do: "notification." <> kind)

  def kinds, do: @kinds

  def list(%Scope{} = scope, limit \\ 30, kind \\ nil) do
    Notification
    |> Repo.scoped(scope)
    |> then(fn query -> if kind in @kinds, do: where(query, [n], n.kind == ^kind), else: query end)
    |> order_by([n], desc: n.inserted_at, desc: n.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Marks one notification read (idempotent)."
  def mark_read(%Scope{} = scope, notification_id) do
    Notification
    |> Repo.scoped(scope)
    |> where([n], n.id == ^notification_id and is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    :ok
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

  # The next moment the account's quiet window ends (today or tomorrow).
  defp quiet_end(account, now) do
    end_hour = account.quiet_hours_end
    today_end = %{now | hour: end_hour, minute: 0, second: 0}

    if DateTime.compare(today_end, now) == :gt do
      today_end
    else
      DateTime.add(today_end, 1, :day)
    end
  end
end
