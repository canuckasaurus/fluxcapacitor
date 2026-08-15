defmodule Flux.Audit do
  @moduledoc """
  Append-only audit trail of consequential workspace actions. Contexts
  record now so history exists before the browsing UI ships (WS7).

  `record/3` is fire-and-forget: it never raises and never fails the
  calling operation — a lost audit row must not abort a mutation.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Repo

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "audit_logs" do
      belongs_to :workspace, Flux.Accounts.Workspace
      belongs_to :actor, Flux.Accounts.Account

      field :action, :string
      field :resource_type, :string
      field :resource_id, :string
      field :metadata, :map, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end

  @doc """
  Records an action. `opts`: `:resource` (a struct with `id`, its type is
  inferred from the module) or `:resource_type`/`:resource_id`, plus
  `:metadata`.

      Flux.Audit.record(scope, "app.delete", resource: app)
  """
  def record(%Scope{} = scope, action, opts \\ []) when is_binary(action) do
    {resource_type, resource_id} = resource_ref(opts)

    workspace_id = Scope.workspace_id(scope)

    Repo.insert(%Entry{
      workspace_id: workspace_id,
      actor_id: Scope.account_id(scope),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: Keyword.get(opts, :metadata, %{})
    })

    # SIEMs subscribe to audit.recorded and ingest the trail live
    # instead of polling the CSV export.
    Flux.Webhooks.dispatch(workspace_id, "audit.recorded", %{
      "action" => action,
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "actor_id" => Scope.account_id(scope),
      "metadata" => Keyword.get(opts, :metadata, %{})
    })

    :ok
  rescue
    # Auditing must never break the audited operation.
    _error -> :ok
  end

  @doc """
  Recent entries for the scope's workspace, newest first (actor preloaded).
  `opts`: `:from`/`:to` (`Date`) bound the window inclusively;
  `:actor_id` keeps one member's actions.
  """
  def list(%Scope{} = scope, limit \\ 50, opts \\ []) do
    Entry
    |> Repo.scoped(scope)
    |> bounded(opts[:from], opts[:to])
    |> by_actor(opts[:actor_id])
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(:actor)
  end

  defp by_actor(query, actor_id) when is_binary(actor_id) and actor_id != "",
    do: where(query, [e], e.actor_id == ^actor_id)

  defp by_actor(query, _none), do: query

  @doc "The audit trail as CSV (same window semantics as `list/3`)."
  def export_csv(%Scope{} = scope, opts \\ []) do
    rows =
      Enum.map(list(scope, 10_000, opts), fn entry ->
        [
          Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M:%S"),
          (entry.actor && entry.actor.email) || "system",
          entry.action,
          entry.resource_type || "",
          entry.resource_id || "",
          (entry.metadata != %{} && Jason.encode!(entry.metadata)) || ""
        ]
      end)

    [["when", "actor", "action", "resource_type", "resource_id", "metadata"] | rows]
    |> Enum.map_join("\r\n", fn row -> Enum.map_join(row, ",", &csv_cell/1) end)
  end

  defp bounded(query, from, to) do
    query
    |> then(fn q ->
      (from && where(q, [e], e.inserted_at >= ^DateTime.new!(from, ~T[00:00:00]))) || q
    end)
    |> then(fn q ->
      (to && where(q, [e], e.inserted_at <= ^DateTime.new!(to, ~T[23:59:59]))) || q
    end)
  end

  defp csv_cell(value) do
    text = to_string(value)

    if String.contains?(text, [",", "\"", "\n"]) do
      "\"" <> String.replace(text, "\"", "\"\"") <> "\""
    else
      text
    end
  end

  defp resource_ref(opts) do
    case Keyword.get(opts, :resource) do
      %module{id: id} ->
        type = module |> Module.split() |> List.last() |> Macro.underscore()
        {type, to_string(id)}

      nil ->
        {Keyword.get(opts, :resource_type), Keyword.get(opts, :resource_id)}
    end
  end
end
