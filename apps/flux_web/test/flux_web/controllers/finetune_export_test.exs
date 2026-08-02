defmodule FluxWeb.FinetuneExportTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "FT WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Tuned App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{conn: log_in_account(conn, account), scope: scope, app: app}
  end

  test "downloads liked replies as JSONL", %{conn: conn, scope: scope, app: app} do
    {:ok, _} = Chat.create_annotation(scope, app, %{question: "Q?", answer: "A."})

    conn = get(conn, ~p"/console/apps/#{app.id}/finetune-export")

    assert response_content_type(conn, :jsonl) =~ "application/jsonl"

    [line] = conn.resp_body |> String.trim() |> String.split("\n")

    assert Jason.decode!(line) == %{
             "messages" => [
               %{"role" => "user", "content" => "Q?"},
               %{"role" => "assistant", "content" => "A."}
             ]
           }
  end

  test "empty exports redirect with a hint", %{conn: conn, app: app} do
    conn = get(conn, ~p"/console/apps/#{app.id}/finetune-export")

    assert redirected_to(conn) == "/console/apps/#{app.id}/monitor"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Nothing to export"
  end
end
