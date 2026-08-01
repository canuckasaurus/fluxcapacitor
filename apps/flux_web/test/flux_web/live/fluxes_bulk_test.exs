defmodule FluxWeb.FluxesBulkTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Bulk WS"})
    scope = Accounts.scope_for(account)

    workflows =
      for name <- ["Alpha Flux", "Beta Flux", "Gamma Flux"] do
        {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => name})
        workflow
      end

    %{conn: log_in_account(conn, account), scope: scope, workflows: workflows}
  end

  test "select some, bulk delete, and the rest survive", %{
    conn: conn,
    scope: scope,
    workflows: [alpha, beta, gamma]
  } do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")

    lv |> element("#select-#{alpha.id}") |> render_click()
    html = lv |> element("#select-#{beta.id}") |> render_click()
    assert html =~ "2 selected"

    html = lv |> element("button", "Delete selected") |> render_click()
    assert html =~ "Deleted 2 flux(es)."

    remaining = Workflows.list_workflows(scope)
    assert Enum.map(remaining, & &1.id) == [gamma.id]
  end

  test "select all then clear", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")

    html = lv |> element("button", "Select all") |> render_click()
    assert html =~ "3 selected"

    html = lv |> element("button", "Clear") |> render_click()
    refute html =~ "selected"
  end

  test "bulk export downloads a multi-document YAML", %{
    conn: conn,
    workflows: [alpha, beta, _gamma]
  } do
    download = get(conn, ~p"/console/fluxes-export?#{[ids: [alpha.id, beta.id]]}")
    assert get_resp_header(download, "content-type") |> hd() =~ "yaml"

    body = response(download, 200)
    assert body =~ "Alpha Flux"
    assert body =~ "Beta Flux"
    assert body =~ "\n---\n"

    # Invalid or empty selections bounce instead of crashing.
    bounced = get(conn, ~p"/console/fluxes-export?#{[ids: ["nope"]]}")
    assert redirected_to(bounced) == ~p"/console/fluxes"
  end
end
