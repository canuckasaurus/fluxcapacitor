defmodule FluxWeb.ToolsLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Tools

  @spec_json """
  {
    "openapi": "3.0.0",
    "info": {"title": "Weather"},
    "servers": [{"url": "https://weather.example.com"}],
    "paths": {
      "/forecast": {
        "get": {
          "operationId": "getForecast",
          "parameters": [
            {"name": "city", "in": "query", "required": true, "schema": {"type": "string"}}
          ]
        }
      }
    }
  }
  """

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Tools UI WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope}
  end

  test "importing a spec creates a toolset and lists operations", %{conn: conn, scope: scope} do
    {:ok, lv, html} = live(conn, ~p"/console/tools")
    assert html =~ "No tools yet"

    lv |> element("button", "Import API") |> render_click()

    html =
      lv
      |> form("form[phx-submit=import]", %{"name" => "", "spec" => @spec_json})
      |> render_submit()

    assert html =~ "Imported 1 operation(s)."
    assert html =~ "Weather"
    assert html =~ "getForecast"
    assert html =~ "/forecast"

    assert [toolset] = Tools.list_toolsets(scope)
    assert toolset.base_url == "https://weather.example.com"
  end

  test "a bad spec surfaces the parse error", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/tools")
    lv |> element("button", "Import API") |> render_click()

    html =
      lv
      |> form("form[phx-submit=import]", %{"name" => "", "spec" => ~s({"paths": {"/x": {}}})})
      |> render_submit()

    assert html =~ "version"
  end

  test "auth and variables save encrypted and show only names", %{conn: conn, scope: scope} do
    {:ok, toolset} = Tools.create_toolset(scope, "Weather", @spec_json)

    {:ok, lv, _html} = live(conn, ~p"/console/tools")
    lv |> element("button[phx-click=expand]") |> render_click()

    html =
      lv
      |> form("form[phx-submit=save_auth]", %{
        "type" => "api_key",
        "in" => "header",
        "name" => "X-Key",
        "value" => "hunter2"
      })
      |> render_submit()

    assert html =~ "auth: api_key"
    refute html =~ "hunter2"

    html =
      lv
      |> form("form[phx-submit=add_variable]", %{"name" => "region", "value" => "top-secret"})
      |> render_submit()

    assert html =~ "region"
    refute html =~ "top-secret"

    saved = Tools.get_toolset(scope, toolset.id)
    refute saved.encrypted_auth =~ "hunter2"
    assert Tools.security_summary(saved).variable_names == ["region"]
  end

  test "the editor tool node panel offers toolsets and operation args", %{
    conn: conn,
    scope: scope
  } do
    {:ok, toolset} = Tools.create_toolset(scope, "Weather", @spec_json)
    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Tool Flux"})

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    render_click(lv, "add_node", %{"type" => "tool"})
    html = render(lv)
    assert html =~ "Choose a toolset…"
    assert html =~ "Weather"

    html =
      lv
      |> element("form[phx-change=update_node]")
      |> render_change(%{"title" => "Tool", "toolset_id" => toolset.id})

    assert html =~ "Choose an operation…"
    assert html =~ "GET /forecast"

    lv
    |> element("form[phx-change=update_node]")
    |> render_change(%{
      "title" => "Tool",
      "toolset_id" => toolset.id,
      "operation_id" => "getForecast"
    })

    html =
      lv
      |> element("form[phx-change=update_node]")
      |> render_change(%{
        "title" => "Tool",
        "toolset_id" => toolset.id,
        "operation_id" => "getForecast",
        "args" => %{"city" => "{{start.query}}"}
      })

    assert html =~ "city"

    saved = Flux.Workflows.get_workflow(scope, workflow.id)
    tool_node = Enum.find(saved.graph["nodes"], &(&1["type"] == "tool"))
    assert tool_node["config"]["operation_id"] == "getForecast"
    assert tool_node["config"]["args"] == %{"city" => "{{start.query}}"}
  end
end
