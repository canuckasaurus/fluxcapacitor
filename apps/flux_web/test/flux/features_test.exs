defmodule Flux.FeaturesTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Features

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Plan WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Plan App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{conn: log_in_account(conn, account), scope: scope, app: app, account: account}
  end

  test "self-hosted default is enterprise with everything enabled", %{scope: scope} do
    assert Features.plan(scope) == "enterprise"
    for feature <- Features.features(), do: assert(Features.enabled?(scope, feature))
  end

  test "lower plans gate the representative features", %{scope: scope, app: app} do
    {:ok, _workspace} = Features.set_plan(scope, "free")
    assert Features.plan(scope) == "free"

    assert {:error, :feature_disabled} =
             Flux.Chat.create_annotation(scope, app, %{question: "q?", answer: "a"})

    assert {:error, :feature_disabled} =
             Flux.RBAC.create_role(scope, %{"name" => "Custom", "permissions" => ["app_preview"]})

    assert {:error, :feature_disabled} = Accounts.enable_scim(scope)

    {:ok, dataset} =
      Flux.RAG.create_dataset(scope, %{
        "name" => "Gated KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    :ok = Flux.Tools.install_plugin(scope, "rss")
    assert {:error, :feature_disabled} = Flux.RAG.sync_datasource(scope, dataset, "rss")

    # team unlocks annotations + datasource sync but not custom roles/SCIM.
    {:ok, _workspace} = Features.set_plan(scope, "team")

    assert {:ok, _annotation} =
             Flux.Chat.create_annotation(scope, app, %{question: "q?", answer: "a"})

    assert {:error, :feature_disabled} = Accounts.enable_scim(scope)

    # Back to enterprise: everything works again.
    {:ok, _workspace} = Features.set_plan(scope, "enterprise")
    assert {:ok, _raw} = Accounts.enable_scim(scope)
  end

  test "only the owner sets the plan, and it is audited", %{scope: scope} do
    assert {:error, :unknown_plan} = Features.set_plan(scope, "platinum")

    {:ok, _workspace} = Features.set_plan(scope, "team")
    actions = Flux.Audit.list(scope, 5) |> Enum.map(& &1.action)
    assert "workspace.plan_set" in actions
  end

  test "the settings plan card switches plans", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/console/settings")
    assert html =~ "Plan"

    html = lv |> form("#plan-form", %{"plan" => "team"}) |> render_change()
    assert html =~ "Plan set to team."
  end
end
