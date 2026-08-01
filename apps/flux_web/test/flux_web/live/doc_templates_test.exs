defmodule FluxWeb.DocTemplatesTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.DocTemplates

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Tpl WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope}
  end

  test "CRUD with jinja validation at save time", %{scope: scope} do
    assert {:ok, template} =
             DocTemplates.create(scope, %{
               "name" => "Offer letter",
               "description" => "HR boilerplate",
               "content" => "Dear {{ start.name | capitalize }}, welcome!"
             })

    # Broken jinja is rejected with the renderer's message.
    assert {:error, changeset} =
             DocTemplates.create(scope, %{"name" => "Broken", "content" => "{% if x %}oops"})

    assert {"invalid template: " <> _reason, _opts} = changeset.errors[:content]

    {:ok, updated} = DocTemplates.update(scope, template, %{"content" => "Hi {{ start.name }}!"})
    assert updated.content == "Hi {{ start.name }}!"

    assert [%{name: "Offer letter"}] = DocTemplates.list(scope)
    {:ok, _deleted} = DocTemplates.delete(scope, template.id)
    assert DocTemplates.list(scope) == []
  end

  test "a template node renders a saved doc template in a real run", %{scope: scope} do
    {:ok, template} =
      DocTemplates.create(scope, %{
        "name" => "Greeting",
        "content" =>
          "{% if start.query == 'vip' %}Welcome back, honored guest!" <>
            "{% else %}Hello {{ start.query | capitalize }}.{% endif %}"
      })

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Doc Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "doc",
          "type" => "template",
          "title" => "Doc",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{"template_id" => template.id}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "doc"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "marty"})
    assert_receive {:run_finished, finished}, 5_000
    assert finished.outputs["output"] == "Hello Marty."

    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "vip"})
    assert_receive {:run_finished, vip_run}, 5_000
    assert vip_run.outputs["output"] == "Welcome back, honored guest!"

    # A deleted template fails the node with a clear error.
    {:ok, _} = DocTemplates.delete(scope, template.id)
    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "x"})
    assert_receive {:run_finished, failed}, 5_000
    assert failed.status == :failed
    assert failed.error =~ "doc template not found"
  end

  test "the library page creates with live preview", %{conn: conn, scope: scope} do
    {:ok, lv, html} = live(conn, ~p"/console/templates")
    assert html =~ "Doc templates"

    lv |> element("button", "New template") |> render_click()

    # Typing re-renders the preview against the sample context.
    html =
      lv
      |> form("#doc-template-form", %{
        "name" => "Echo card",
        "description" => "",
        "content" => "Q: {{ start.query | upper }}",
        "context" => ~s({"start": {"query": "hello"}})
      })
      |> render_change()

    assert html =~ "Q: HELLO"

    # Bad jinja shows the error inline in the preview.
    html =
      lv
      |> form("#doc-template-form", %{"content" => "{% for x %}"})
      |> render_change()

    assert html =~ "unknown tag"

    lv
    |> form("#doc-template-form", %{
      "name" => "Echo card",
      "content" => "Q: {{ start.query | upper }}"
    })
    |> render_submit()

    assert [%{name: "Echo card"}] = DocTemplates.list(scope)
  end
end
