defmodule FluxWeb.ConsoleHooks do
  @moduledoc """
  `on_mount` hooks shared by console LiveViews.

  `:require_workspace` sends accounts that belong to no workspace into the
  workspace-creation onboarding before they can use any console section.
  """
  use FluxWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Flux.Accounts

  def on_mount(:require_workspace, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if scope.workspace do
      {:cont, assign(socket, :workspaces, Accounts.list_workspaces(scope.account))}
    else
      {:halt, redirect(socket, to: ~p"/console/workspaces/new")}
    end
  end
end
