defmodule FluxWeb.PageController do
  use FluxWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.account do
      redirect(conn, to: ~p"/console")
    else
      render(conn, :home)
    end
  end
end
