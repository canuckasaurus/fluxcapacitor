defmodule FluxWeb.Plugs.RequirePermission do
  @moduledoc """
  Router/controller-level RBAC: halts browser requests whose scope lacks
  the given permission, complementing the context-level checks (defense
  in depth — a route stays closed even if a context check is missed).

      plug FluxWeb.Plugs.RequirePermission, :app_import_export_dsl
  """
  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  def init(permission) when is_atom(permission), do: permission

  def call(conn, permission) do
    if Flux.RBAC.can?(conn.assigns[:current_scope], permission) do
      conn
    else
      conn
      |> put_flash(:error, "You don't have permission to do that.")
      |> redirect(to: "/console")
      |> halt()
    end
  end
end
