defmodule Flux.Repo do
  use Ecto.Repo,
    otp_app: :flux,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query

  alias Flux.Accounts.Scope

  # Tables that hold tenant-owned rows. Every read of these tables must carry
  # a workspace_id filter (usually via scoped/2) or explicitly opt out with
  # `skip_workspace_guard: true` — reserved for platform-admin and bulk-ops
  # code paths and token-based lookups that resolve tenancy from the row.
  #
  # Grows as domain tables land (datasets, workflows, ...).
  @tenant_tables MapSet.new(
                   ~w(invitations provider_credentials apps conversations messages api_tokens
                      workflows workflow_versions workflow_runs api_toolsets uploaded_files
                      workflow_triggers datasets rag_documents rag_segments rag_entities
                      rag_entity_mentions annotations doc_templates interviews
                      webhook_endpoints workflow_batches)
                 )

  @doc """
  Narrows a queryable to the scope's workspace.

  Raises if the scope has no active workspace — callers must never fall
  through to an unscoped query.
  """
  def scoped(queryable, %Scope{} = scope) do
    case Scope.workspace_id(scope) do
      nil ->
        raise ArgumentError,
              "cannot build a workspace-scoped query from a scope without a workspace"

      workspace_id ->
        from(q in queryable, where: q.workspace_id == ^workspace_id)
    end
  end

  @impl true
  def prepare_query(_operation, query, opts) do
    if opts[:skip_workspace_guard] || not tenant_table?(query) ||
         references_workspace_id?(query) do
      {query, opts}
    else
      raise Flux.Repo.UnscopedQueryError, query: query
    end
  end

  defp tenant_table?(%Ecto.Query{from: %{source: {table, _schema}}}) when is_binary(table),
    do: MapSet.member?(@tenant_tables, table)

  defp tenant_table?(_query), do: false

  defp references_workspace_id?(%Ecto.Query{} = query) do
    exprs =
      Enum.map(query.wheres, & &1.expr) ++
        Enum.flat_map(query.joins, fn
          %{on: %{expr: expr}} -> [expr]
          _join -> []
        end)

    Enum.any?(exprs, &expr_references_workspace_id?/1)
  end

  defp expr_references_workspace_id?({{:., _, [_binding, :workspace_id]}, _, _}), do: true

  defp expr_references_workspace_id?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&expr_references_workspace_id?/1)

  defp expr_references_workspace_id?(list) when is_list(list),
    do: Enum.any?(list, &expr_references_workspace_id?/1)

  defp expr_references_workspace_id?(_other), do: false
end

defmodule Flux.Repo.UnscopedQueryError do
  @moduledoc """
  Raised when a query against a tenant-owned table carries no workspace_id
  filter. Build the query with `Flux.Repo.scoped/2`, add an explicit
  workspace_id predicate, or — only in platform-admin/bulk code — pass
  `skip_workspace_guard: true`.
  """
  defexception [:query]

  @impl true
  def message(%{query: query}) do
    """
    unscoped query against a tenant-owned table:

        #{inspect(query)}

    Tenant tables must be queried through Flux.Repo.scoped/2 (or with an
    explicit workspace_id filter). If this cross-workspace read is
    intentional, pass `skip_workspace_guard: true`.
    """
  end
end
