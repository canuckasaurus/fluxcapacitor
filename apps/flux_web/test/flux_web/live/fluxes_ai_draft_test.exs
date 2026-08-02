defmodule FluxWeb.FluxesAiDraftTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  # Copilot.draft runs inside the LiveView process, so the fakes are
  # self-contained modules selected via config — no test-process state.
  defmodule GoodModel do
    def generate(_messages) do
      graph = %{
        "name" => "Complaint triage",
        "nodes" => [
          %{
            "id" => "start",
            "type" => "start",
            "title" => "Start",
            "config" => %{
              "variables" => [
                %{
                  "name" => "complaint",
                  "label" => "Complaint",
                  "type" => "text",
                  "required" => true
                }
              ]
            }
          },
          %{
            "id" => "t",
            "type" => "template",
            "title" => "Summarize",
            "config" => %{"template" => "Received: {{start.complaint}}"}
          },
          %{
            "id" => "end",
            "type" => "end",
            "title" => "End",
            "config" => %{"outputs" => [%{"key" => "summary", "value" => "{{t.output}}"}]}
          }
        ],
        "edges" => [
          %{"source" => "start", "source_handle" => "default", "target" => "t"},
          %{"source" => "t", "source_handle" => "default", "target" => "end"}
        ]
      }

      {:ok, Jason.encode!(graph)}
    end
  end

  defmodule BrokenModel do
    def generate(_messages), do: {:ok, "I am unable to produce graphs today."}
  end

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Draft WS"})
    scope = Accounts.scope_for(account)

    on_exit(fn -> Application.delete_env(:flux, Flux.Workflows.Copilot) end)

    %{conn: log_in_account(conn, account), scope: scope}
  end

  test "describing a flux drafts it and lands on the canvas", %{conn: conn, scope: scope} do
    Application.put_env(:flux, Flux.Workflows.Copilot, module: GoodModel)

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")
    lv |> element("button", "New Flux") |> render_click()

    lv
    |> form("form[phx-submit=ai_draft]", %{
      "description" => "Triage customer complaints and summarize them"
    })
    |> render_submit()

    {path, flash} = assert_redirect(lv)
    assert flash["info"] =~ ~s(Drafted "Complaint triage")

    [workflow] = Workflows.list_workflows(scope)
    assert path == "/console/fluxes/#{workflow.id}"
    assert workflow.name == "Complaint triage"
    assert workflow.description =~ "Triage customer complaints"
    assert length(workflow.graph["nodes"]) == 3
    assert Enum.all?(workflow.graph["nodes"], &match?(%{"position" => %{}}, &1))
  end

  test "an unusable model reply is an error flash, nothing created", %{conn: conn, scope: scope} do
    Application.put_env(:flux, Flux.Workflows.Copilot, module: BrokenModel)

    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")
    lv |> element("button", "New Flux") |> render_click()

    html =
      lv
      |> form("form[phx-submit=ai_draft]", %{"description" => "anything"})
      |> render_submit()

    assert html =~ "could not produce a valid flux"
    assert Workflows.list_workflows(scope) == []
  end

  test "without a workspace default model the helper points at Plugins", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")
    lv |> element("button", "New Flux") |> render_click()

    html =
      lv
      |> form("form[phx-submit=ai_draft]", %{"description" => "anything"})
      |> render_submit()

    assert html =~ "default model"
  end

  test "the helper card shows the mascot and ships the static asset", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes")
    html = lv |> element("button", "New Flux") |> render_click()

    assert html =~ "/images/ai-helper.jpg"
    assert File.exists?(Path.join(:code.priv_dir(:flux_web), "static/images/ai-helper.jpg"))
  end
end
