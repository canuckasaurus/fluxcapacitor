defmodule FluxWeb.ConsoleHooks do
  @moduledoc """
  `on_mount` hooks shared by console LiveViews.

  `:require_workspace` sends accounts that belong to no workspace into the
  workspace-creation onboarding before they can use any console section.
  """
  use FluxWeb, :verified_routes

  import Phoenix.LiveView

  def on_mount(:require_workspace, _params, _session, socket) do
    if socket.assigns.current_scope.workspace do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: ~p"/console/workspaces/new")}
    end
  end
end
