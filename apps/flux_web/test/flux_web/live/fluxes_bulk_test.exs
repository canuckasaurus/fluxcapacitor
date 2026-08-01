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

  test "deleted fluxes go to the trash, restore and purge work", %{
    conn: conn,
    scope: scope,
    workflows: [alpha | _rest]
  } do
    {:ok, published} = Workflows.publish(scope, put_echo(scope, alpha))
    assert published

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")
    html = lv |> element("#workflow-#{alpha.id} button", "Delete") |> render_click()

    # Gone from the grid, present in the trash; not really deleted.
    refute html =~ ~s(id="workflow-#{alpha.id}")
    assert html =~ "Trash (1)"
    assert {:error, :not_found} = Workflows.get_workflow(scope, alpha.id)
    assert [%{id: trashed_id}] = Workflows.list_trashed_workflows(scope)
    assert trashed_id == alpha.id

    # Trashed fluxes stop serving their public site.
    assert {:error, :not_found} = Workflows.get_workflow_by_site_token(alpha.site_token)

    html = lv |> element("button", "Restore") |> render_click()
    assert html =~ ~s(id="workflow-#{alpha.id}")
    assert %Workflows.Workflow{} = Workflows.get_workflow(scope, alpha.id)

    # Purge is final.
    lv |> element("#workflow-#{alpha.id} button", "Delete") |> render_click()
    html = lv |> element("button", "Delete forever") |> render_click()
    refute html =~ "Trash ("
    assert Workflows.list_trashed_workflows(scope) == []
    assert {:error, :not_found} = Workflows.get_workflow(scope, alpha.id)
  end

  defp put_echo(scope, workflow) do
    graph =
      update_in(workflow.graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node ->
            node
            |> put_in(["config", "provider_plugin_id"], "echo")
            |> put_in(["config", "model"], "echo-1")

          node ->
            node
        end)
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, workflow} = Workflows.enable_site(scope, workflow)
    workflow
  end

  test "trashed workflows refuse chatflow turns and sub-flux calls", %{
    scope: scope,
    workflows: [alpha | _rest]
  } do
    alpha = put_echo(scope, alpha)
    {:ok, _version} = Workflows.publish(scope, alpha)

    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Chatflow On Trash",
        "mode" => "advanced_chat",
        "workflow_id" => alpha.id
      })

    {:ok, _trashed} = Workflows.delete_workflow(scope, alpha)

    conversation = Flux.Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Flux.Chat.send_message(scope, app, conversation, "anyone home?")
    assert_receive {:error, failed}, 5_000
    assert failed.error =~ "no published flux"
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
