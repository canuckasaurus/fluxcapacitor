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

  test "endpoint requests are rate limited per token", %{conn: conn, scope: scope} do
    :ok = Tools.install_plugin(scope, "utility")
    token = Tools.endpoint_token(scope, "utility")

    # Exhaust the per-token bucket directly, then the next request is refused.
    Enum.each(1..120, fn _n ->
      FluxWeb.RateLimit.hit("plugin-endpoint:#{token}", 60_000, 120)
    end)

    limited = get(conn, "/e/#{token}/time")
    assert json_response(limited, 429)["error"] =~ "rate limit"
    assert get_resp_header(limited, "retry-after") == ["60"]
  end

  test "segment and auto-sync mutations leave an audit trail", %{scope: scope} do
    {:ok, dataset} =
      Flux.RAG.create_dataset(scope, %{
        "name" => "Audit KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    {:ok, _doc} = Flux.RAG.add_document(scope, dataset, %{name: "a.md", content: "Hello world"})
    Oban.drain_queue(queue: :ingest)
    [segment] = Flux.RAG.list_segments(scope, hd(Flux.RAG.list_documents(scope, dataset.id)).id)

    {:ok, _} = Flux.RAG.update_segment(scope, segment.id, "Hello edited world")
    {:ok, _} = Flux.RAG.set_segment_enabled(scope, segment.id, false)
    {:ok, _} = Flux.RAG.delete_segment(scope, segment.id)

    :ok = Tools.install_plugin(scope, "rss")

    {:ok, _} =
      Flux.RAG.update_dataset(scope, dataset, %{
        "sync_plugin_id" => "rss",
        "sync_interval_minutes" => 30
      })

    actions = Flux.Audit.list(scope, 20) |> Enum.map(& &1.action)
    assert "segment.update" in actions
    assert "segment.set_enabled" in actions
    assert "segment.delete" in actions
    assert "dataset.auto_sync_config" in actions
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
