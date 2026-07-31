defmodule FluxWeb.AppChatLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Chat UI WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "UI Echo",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{conn: log_in_account(conn, account), app: app, scope: scope}
  end

  test "apps index lists apps and links to chat", %{conn: conn, app: app} do
    {:ok, _lv, html} = live(conn, ~p"/console/apps")
    assert html =~ app.name
    assert html =~ "Open chat"
  end

  test "sending a message streams and completes", %{conn: conn, app: app} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    lv
    |> form("#chat-form", %{"content" => "hello ui"})
    |> render_submit()

    # Poll until the streamed reply lands in the completed message list.
    html = poll_until(lv, "You said: hello ui", 50)
    assert html =~ "You said: hello ui"
  end

  test "creating an API key shows the raw token once", %{conn: conn, app: app} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    html = lv |> element("button", "Create key") |> render_click()
    assert html =~ "app-"
    assert html =~ "Copy this key now"
  end

  describe "completion apps" do
    setup %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "UI Summarizer",
          "mode" => "completion",
          "provider_plugin_id" => "echo",
          "model" => "echo-1",
          "prompt_template" => "Summarize: {{inputs.text}}"
        })

      %{completion_app: app}
    end

    test "apps index creates a completion app with a template", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/console/apps")

      lv |> element("button", "New app") |> render_click()

      html =
        lv
        |> form("#app-form")
        |> render_change(%{"app" => %{"mode" => "completion"}})

      assert html =~ "Prompt template"

      lv
      |> form("#app-form", %{
        "app" => %{
          "name" => "Form App",
          "mode" => "completion",
          "prompt_template" => "Echo: {{inputs.q}}"
        }
      })
      |> render_submit()

      created = Enum.find(Chat.list_apps(scope), &(&1.name == "Form App"))
      assert created.mode == :completion
      assert created.prompt_template == "Echo: {{inputs.q}}"
    end

    test "saving configuration persists template and variables", %{
      conn: conn,
      scope: scope,
      completion_app: app
    } do
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

      lv |> element("button", "Add variable") |> render_click()

      html =
        lv
        |> form("#settings-form", %{
          "prompt_template" => "Summarize briefly: {{inputs.text}}",
          "vars" => %{
            "0" => %{
              "variable" => "text",
              "label" => "Text to summarize",
              "type" => "paragraph",
              "required" => "true"
            }
          }
        })
        |> render_submit()

      assert html =~ "Configuration saved."
      assert html =~ "Text to summarize"

      saved = Chat.get_app(scope, app.id)
      assert saved.prompt_template == "Summarize briefly: {{inputs.text}}"

      assert saved.input_form == [
               %{
                 "variable" => "text",
                 "label" => "Text to summarize",
                 "type" => "paragraph",
                 "required" => true
               }
             ]
    end

    test "running a completion streams the rendered template", %{
      conn: conn,
      scope: scope,
      completion_app: app
    } do
      {:ok, _app} =
        Chat.update_app(scope, app, %{
          "input_form" => [
            %{"variable" => "text", "label" => "Text", "type" => "paragraph", "required" => true}
          ]
        })

      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")
      assert html =~ "completion-form"

      lv
      |> form("#completion-form", %{"inputs" => %{"text" => "flux ping"}})
      |> render_submit()

      html = poll_until(lv, "You said: Summarize: flux ping", 50)
      assert html =~ "You said: Summarize: flux ping"

      # Wait for generation to finalize (cursor gone) so the streaming task
      # doesn't outlive the test's DB sandbox ownership.
      refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"
    end
  end

  defp poll_until_gone(lv, needle, retries) do
    html = render(lv)

    cond do
      not (html =~ needle) ->
        html

      retries == 0 ->
        html

      true ->
        Process.sleep(50)
        poll_until_gone(lv, needle, retries - 1)
    end
  end

  defp poll_until(lv, needle, retries) do
    html = render(lv)

    cond do
      html =~ needle ->
        html

      retries == 0 ->
        html

      true ->
        Process.sleep(50)
        poll_until(lv, needle, retries - 1)
    end
  end
end
