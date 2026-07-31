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

    Repo.insert(%Entry{
      workspace_id: Scope.workspace_id(scope),
      actor_id: Scope.account_id(scope),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: Keyword.get(opts, :metadata, %{})
    })

    :ok
  rescue
    # Auditing must never break the audited operation.
    _error -> :ok
  end

  @doc "Recent entries for the scope's workspace, newest first (actor preloaded)."
  def list(%Scope{} = scope, limit \\ 50) do
    Entry
    |> Repo.scoped(scope)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(:actor)
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
