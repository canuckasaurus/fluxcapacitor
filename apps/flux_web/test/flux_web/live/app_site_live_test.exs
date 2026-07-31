defmodule FluxWeb.AppSiteLiveTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Site WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Public Echo",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{scope: scope, app: app, account: account}
  end

  test "unknown or disabled tokens render the unavailable page", %{conn: conn, scope: scope, app: app} do
    {:ok, _lv, html} = live(conn, ~p"/site/site_nope")
    assert html =~ "This app is not available."

    {:ok, published} = Chat.enable_site(scope, app)
    {:ok, disabled} = Chat.disable_site(scope, published)

    {:ok, _lv, html} = live(conn, ~p"/site/#{disabled.site_token}")
    assert html =~ "This app is not available."
  end

  test "published chat app works anonymously and tags the end user", %{
    conn: conn,
    scope: scope,
    app: app
  } do
    {:ok, app} = Chat.enable_site(scope, app)

    # No log_in_account — the public page needs no session.
    {:ok, lv, html} = live(conn, ~p"/site/#{app.site_token}")
    assert html =~ "Public Echo"

    lv |> form("#site-chat-form", %{"content" => "hello public"}) |> render_submit()

    html = poll_until(lv, "You said: hello public", 50)
    assert html =~ "You said: hello public"
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"

    [conversation] = Chat.list_conversations(scope, app.id)
    assert String.starts_with?(conversation.end_user_ref, "web_")
  end

  test "published completion app renders the form and streams output", %{
    conn: conn,
    scope: scope
  } do
    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Public Summarizer",
        "mode" => "completion",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "prompt_template" => "Sum: {{inputs.text}}",
        "input_form" => [
          %{"variable" => "text", "label" => "Text", "type" => "paragraph", "required" => true}
        ]
      })

    {:ok, app} = Chat.enable_site(scope, app)

    {:ok, lv, html} = live(conn, ~p"/site/#{app.site_token}")
    assert html =~ "site-completion-form"
    assert html =~ "Text"

    lv |> form("#site-completion-form", %{"inputs" => %{"text" => "public ping"}}) |> render_submit()

    html = poll_until(lv, "You said: Sum: public ping", 50)
    assert html =~ "You said: Sum: public ping"
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"
  end

  test "site responses allow cross-origin framing", %{conn: conn, scope: scope, app: app} do
    {:ok, app} = Chat.enable_site(scope, app)

    conn = get(conn, ~p"/site/#{app.site_token}")
    assert get_resp_header(conn, "x-frame-options") == []
    assert get_resp_header(conn, "content-security-policy") == ["frame-ancestors *"]
  end

  test "console card publishes and unpublishes the site", %{
    conn: conn,
    account: account,
    app: app,
    scope: scope
  } do
    conn = log_in_account(conn, account)
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    html = lv |> element("button", "Publish site") |> render_click()
    assert html =~ "/site/site_"
    assert html =~ "&lt;iframe"

    saved = Chat.get_app(scope, app.id)
    assert saved.site_enabled
    assert String.starts_with?(saved.site_token, "site_")

    html = lv |> element("button", "Unpublish") |> render_click()
    refute html =~ "Unpublish"
    refute Chat.get_app(scope, app.id).site_enabled
    # Token survives so the URL is stable on re-publish.
    assert Chat.get_app(scope, app.id).site_token == saved.site_token
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
