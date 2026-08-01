defmodule FluxWeb.WorkspaceExportTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Export WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope}
  end

  test "the archive carries fluxes, apps, datasets, and scrubbed settings", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Exported Flux"})

    {:ok, _app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Exported App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, dataset} =
      Flux.RAG.create_dataset(scope, %{
        "name" => "Exported KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    {:ok, _doc} =
      Flux.RAG.add_document(scope, dataset, %{name: "notes.md", content: "export me"})

    # A secret lands in custom_config; it must not leave.
    {:ok, _raw} = Accounts.enable_scim(scope)

    conn = get(conn, ~p"/console/workspace-export")
    payload = conn |> response(200) |> Jason.decode!()

    assert payload["format"] == "fluxcapacitor-workspace-export"
    assert payload["workspace"]["name"] == "Export WS"
    refute Map.has_key?(payload["workspace"]["settings"], "scim_token_hash")

    assert [%{"name" => "Exported Flux", "dsl" => flux_dsl}] = payload["fluxes"]
    assert flux_dsl =~ "Exported Flux"

    assert [%{"name" => "Exported App", "dsl" => app_dsl}] = payload["apps"]
    assert app_dsl =~ "Exported App"

    assert [%{"name" => "Exported KB", "documents" => [doc], "settings" => settings}] =
             payload["datasets"]

    assert doc == %{"name" => "notes.md", "content" => "export me"}
    assert settings["embedding_model"] == "echo-embed"
  end

  test "an export round-trips into a fresh workspace", %{conn: conn, scope: scope} do
    {:ok, _workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Round Trip Flux"})

    {:ok, _app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Round Trip App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, dataset} =
      Flux.RAG.create_dataset(scope, %{
        "name" => "Round Trip KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    {:ok, _doc} = Flux.RAG.add_document(scope, dataset, %{name: "a.md", content: "round trip"})

    json = conn |> get(~p"/console/workspace-export") |> response(200)

    # A different account imports the archive into a brand-new workspace.
    other = account_fixture()
    {:ok, {_ws2, _}} = Accounts.create_workspace(other, %{name: "Target WS"})
    target_scope = Accounts.scope_for(other)

    assert {:ok, counts} = Flux.Import.workspace(target_scope, json)
    assert counts.fluxes == 1
    assert counts.apps == 1
    assert counts.datasets == 1
    assert counts.documents == 1

    assert [imported_flux] = Flux.Workflows.list_workflows(target_scope)
    assert imported_flux.name == "Round Trip Flux"
    assert [imported_app] = Flux.Chat.list_apps(target_scope)
    assert imported_app.name == "Round Trip App"
    assert [imported_dataset] = Flux.RAG.list_datasets(target_scope)
    assert [document] = Flux.RAG.list_documents(target_scope, imported_dataset.id)
    assert document.content == "round trip"

    # The upload endpoint reports the same counts through the flash.
    path = Path.join(System.tmp_dir!(), "ws-export.json")
    File.write!(path, json)

    upload = %Plug.Upload{
      path: path,
      filename: "ws-export.json",
      content_type: "application/json"
    }

    other_conn =
      build_conn()
      |> log_in_account(other)
      |> post(~p"/console/workspace-import", %{"archive" => upload})

    assert redirected_to(other_conn) == ~p"/console/settings"
    assert Phoenix.Flash.get(other_conn.assigns.flash, :info) =~ "Imported 1 flux(es)"

    # Garbage archives are refused, not crashed on.
    assert {:error, message} = Flux.Import.workspace(target_scope, "{\"nope\": true}")
    assert message =~ "not a FluxCapacitor"
  end

  test "members without export permission are refused", %{conn: _conn, scope: scope} do
    viewer = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: Flux.Accounts.Scope.workspace_id(scope),
        account_id: viewer.id,
        role: :normal
      })
      |> Flux.Repo.insert()

    {:ok, _} =
      Accounts.switch_workspace(viewer, Flux.Accounts.Scope.workspace_id(scope))

    conn = build_conn() |> log_in_account(viewer) |> get(~p"/console/workspace-export")
    assert conn.status in [302, 403]
  end
end
