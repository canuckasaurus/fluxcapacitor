defmodule FluxWeb.ToolPluginsTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Tools
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Plugin WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope, workspace: workspace}
  end

  test "install from the Plugins page, then a tool node calls the plugin", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    # Not installed → no pseudo-toolset, invocation refused.
    assert Tools.installed_plugin_toolsets(scope) == []

    assert {:error, :plugin_not_installed} =
             Tools.invoke_for_workspace(workspace.id, "plugin:utility", "calculate", %{
               "expression" => "1+1"
             })

    {:ok, lv, _html} = live(conn, ~p"/console/plugins")
    html = lv |> element("button", "Install") |> render_click()
    assert html =~ "installed"

    assert [%{id: "plugin:utility", operations: operations}] =
             Tools.installed_plugin_toolsets(scope)

    assert Enum.any?(operations, &(&1["operation_id"] == "calculate"))

    # A flux tool node bound to the plugin toolset runs end-to-end.
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Calc Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [
              %{"name" => "query", "label" => "Q", "type" => "text", "required" => true}
            ]
          }
        },
        %{
          "id" => "tool_1",
          "type" => "tool",
          "title" => "Calc",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{
            "toolset_id" => "plugin:utility",
            "operation_id" => "calculate",
            "args" => %{"expression" => "{{start.query}}"}
          }
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "position" => %{"x" => 600, "y" => 0},
          "config" => %{"answer" => "= {{tool_1.text}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "tool_1"},
        %{
          "id" => "e2",
          "source" => "tool_1",
          "source_handle" => "default",
          "target" => "answer_1"
        }
      ]
    }

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "(2+3)*4"})

    finished =
      receive do
        {:run_finished, finished} -> finished
      after
        5_000 -> flunk("run did not finish")
      end

    assert finished.status == :succeeded
    assert finished.outputs["answer"] == "= 20"
  end
end
