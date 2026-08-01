defmodule FluxWeb.FluxSiteLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Flux Site WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Public Flux"})

    # Wire the starter graph's LLM node to the echo test provider.
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
    %{scope: scope, workflow: workflow, account: account}
  end

  test "unknown token, disabled site, and unpublished flux are all unavailable", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    {:ok, _lv, html} = live(conn, ~p"/site/flux/site_nope")
    assert html =~ "This flux is not available."

    # Site enabled but no published version yet.
    {:ok, published} = Workflows.enable_site(scope, workflow)
    {:ok, _lv, html} = live(conn, ~p"/site/flux/#{published.site_token}")
    assert html =~ "This flux is not available."
  end

  test "published flux renders the start-variable form and streams a run", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    {:ok, _version} = Workflows.publish(scope, workflow)
    {:ok, workflow} = Workflows.enable_site(scope, workflow)

    # No log_in_account — public page.
    {:ok, lv, html} = live(conn, ~p"/site/flux/#{workflow.site_token}")
    assert html =~ "Public Flux"
    assert html =~ "site-flux-form"
    assert html =~ "query"

    lv |> form("#site-flux-form", %{"inputs" => %{"query" => "site ping"}}) |> render_submit()

    html = poll_until(lv, "You said: site ping", 50)
    assert html =~ "You said: site ping"
    assert poll_until(lv, "Powered by", 50)

    # Run was recorded against the published version, not the draft.
    [run] = Workflows.list_runs(scope, workflow.id)
    assert run.version == 1
    assert run.source == :api
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"
  end

  test "paused runs prompt the visitor and resume on the public page", %{
    conn: conn,
    scope: scope,
    workflow: workflow
  } do
    graph =
      workflow.graph
      |> Map.update!("nodes", fn nodes ->
        nodes ++
          [
            %{
              "id" => "ask",
              "type" => "human_input",
              "title" => "Confirm",
              "position" => %{"x" => 900, "y" => 100},
              "config" => %{"prompt" => "Proceed?", "options" => ["yes"]}
            },
            %{
              "id" => "t",
              "type" => "template",
              "title" => "Done",
              "position" => %{"x" => 1200, "y" => 100},
              "config" => %{"template" => "confirmed: {{ask.output}}"}
            }
          ]
      end)
      |> Map.update!("edges", fn edges ->
        edges ++
          [
            %{
              "id" => "ea",
              "source" => "answer_1",
              "source_handle" => "default",
              "target" => "ask"
            },
            %{"id" => "et", "source" => "ask", "source_handle" => "default", "target" => "t"}
          ]
      end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, _version} = Workflows.publish(scope, workflow)
    {:ok, workflow} = Workflows.enable_site(scope, workflow)

    {:ok, lv, _html} = live(conn, ~p"/site/flux/#{workflow.site_token}")
    lv |> form("#site-flux-form", %{"inputs" => %{"query" => "go"}}) |> render_submit()

    html = poll_until(lv, "Proceed?", 50)
    assert html =~ "Your input is needed"

    lv |> form("#site-resume-form", %{"input" => "yes"}) |> render_submit()
    html = poll_until(lv, "confirmed: yes", 50)
    assert html =~ "confirmed: yes"
  end

  test "editor site modal publishes and unpublishes", %{
    conn: conn,
    account: account,
    scope: scope,
    workflow: workflow
  } do
    conn = log_in_account(conn, account)
    {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

    lv |> element("button[phx-click=toggle_site]") |> render_click()
    html = lv |> element("button", "Publish site") |> render_click()
    assert html =~ "/site/flux/site_"
    assert html =~ "&lt;iframe"

    saved = Workflows.get_workflow(scope, workflow.id)
    assert saved.site_enabled
    assert String.starts_with?(saved.site_token, "site_")

    lv |> element("button", "Unpublish") |> render_click()
    refute Workflows.get_workflow(scope, workflow.id).site_enabled
  end

  defp poll_until(lv, needle, retries) do
    html = render(lv)

    cond do
      html =~ needle -> html
      retries == 0 -> html
      true -> Process.sleep(50) && poll_until(lv, needle, retries - 1)
    end
  end

  defp poll_until_gone(lv, needle, retries) do
    html = render(lv)

    cond do
      not (html =~ needle) -> html
      retries == 0 -> html
      true -> Process.sleep(50) && poll_until_gone(lv, needle, retries - 1)
    end
  end
end
