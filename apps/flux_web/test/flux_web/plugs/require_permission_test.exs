defmodule FluxWeb.Plugs.RequirePermissionTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup %{conn: conn} do
    owner = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(owner, %{name: "RBAC Plug WS"})
    owner_scope = Accounts.scope_for(owner)
    {:ok, workflow} = Workflows.create_workflow(owner_scope, %{"name" => "Guarded Flux"})

    member = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: member.id,
        role: :normal
      })
      |> Flux.Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace.id)

    %{conn: conn, owner: owner, member: member, workflow: workflow}
  end

  test "export allows roles holding app_import_export_dsl", %{
    conn: conn,
    owner: owner,
    workflow: workflow
  } do
    conn =
      conn
      |> log_in_account(owner)
      |> get(~p"/console/fluxes/#{workflow.id}/export")

    assert response(conn, 200) =~ ~s("kind": "app")
  end

  test "export redirects roles lacking the permission", %{
    conn: conn,
    member: member,
    workflow: workflow
  } do
    conn =
      conn
      |> log_in_account(member)
      |> get(~p"/console/fluxes/#{workflow.id}/export")

    assert redirected_to(conn) == "/console"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "You don't have permission"
  end
end
