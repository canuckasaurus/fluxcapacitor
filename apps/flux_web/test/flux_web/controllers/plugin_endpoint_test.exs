defmodule FluxWeb.PluginEndpointTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Tools

  setup do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "EP WS"})
    %{scope: Accounts.scope_for(account)}
  end

  test "unknown tokens 404", %{conn: conn} do
    assert conn |> get("/e/ep_nope/time") |> json_response(404)
    assert conn |> get("/e/whatever") |> json_response(404)
  end

  test "installed utility plugin serves time and calculate", %{conn: conn, scope: scope} do
    :ok = Tools.install_plugin(scope, "utility")
    token = Tools.endpoint_token(scope, "utility")
    assert String.starts_with?(token, "ep_")

    body = conn |> get("/e/#{token}/time") |> json_response(200)
    assert {:ok, _time, _offset} = DateTime.from_iso8601(body["iso8601"])

    body =
      conn
      |> get("/e/#{token}/calculate", %{"expression" => "(2+3)*4"})
      |> json_response(200)

    assert body["result"] == 20.0

    body =
      conn
      |> get("/e/#{token}/calculate", %{"expression" => "2/0"})
      |> json_response(422)

    assert body["error"] =~ "division by zero"

    # Unknown paths are the plugin's decision — utility answers 404 itself.
    assert conn |> get("/e/#{token}/nope") |> json_response(404)
  end

  test "plugins without endpoint support 404, uninstall revokes the URL", %{
    conn: conn,
    scope: scope
  } do
    :ok = Tools.install_plugin(scope, "rss")
    rss_token = Tools.endpoint_token(scope, "rss")
    assert conn |> get("/e/#{rss_token}/anything") |> json_response(404)

    :ok = Tools.install_plugin(scope, "utility")
    token = Tools.endpoint_token(scope, "utility")
    assert conn |> get("/e/#{token}/time") |> json_response(200)

    :ok = Tools.uninstall_plugin(scope, "utility")
    assert conn |> get("/e/#{token}/time") |> json_response(404)
  end
end
