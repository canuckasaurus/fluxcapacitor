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

  test "unknown or disabled tokens render the unavailable page", %{
    conn: conn,
    scope: scope,
    app: app
  } do
    {:ok, _lv, html} = live(conn, ~p"/site/site_nope")
    assert html =~ "This app is not available."

    {:ok, published} = Chat.enable_site(scope, app)
    {:ok, disabled} = Chat.disable_site(scope, published)

    # Disabled (not deleted) shows the maintenance page since batch 30.
    {:ok, _lv, html} = live(conn, ~p"/site/#{disabled.site_token}")
    assert html =~ "site-maintenance"
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

    lv
    |> form("#site-completion-form", %{"inputs" => %{"text" => "public ping"}})
    |> render_submit()

    html = poll_until(lv, "You said: Sum: public ping", 50)
    assert html =~ "You said: Sum: public ping"
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"
  end

  test "opening statement + suggested questions flow to the public site and /v1", %{
    conn: conn,
    scope: scope,
    app: app,
    account: account
  } do
    # Save via the console chat-settings card.
    console = log_in_account(conn, account)
    {:ok, lv, _html} = live(console, ~p"/console/apps/#{app.id}")

    lv
    |> form("#chat-settings-form", %{
      "opening_statement" => "Welcome! Ask me anything.",
      "suggested_questions_text" => "What can you do?\nHow do refunds work?"
    })
    |> render_submit()

    {:ok, app} = {:ok, Chat.get_app(scope, app.id)}
    assert app.opening_statement == "Welcome! Ask me anything."
    assert app.suggested_questions == ["What can you do?", "How do refunds work?"]

    # Public site shows both; clicking a suggestion sends it.
    {:ok, app} = Chat.enable_site(scope, app)
    {:ok, lv, html} = live(conn, ~p"/site/#{app.site_token}")
    assert html =~ "Welcome! Ask me anything."
    assert html =~ "How do refunds work?"

    lv |> element("button", "What can you do?") |> render_click()
    html = poll_until(lv, "You said: What can you do?", 50)
    assert html =~ "You said: What can you do?"
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"

    # /v1/parameters serves the real values.
    {:ok, _token, raw} = Chat.create_api_token(scope, app)

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get(~p"/v1/parameters")
      |> json_response(200)

    assert body["opening_statement"] == "Welcome! Ask me anything."
    assert body["suggested_questions"] == ["What can you do?", "How do refunds work?"]
  end

  test "embed.js is served and the console shows the bubble snippet", %{
    conn: conn,
    scope: scope,
    app: app,
    account: account
  } do
    body = conn |> get("/embed.js") |> response(200)
    assert body =~ "data-flux-site"

    {:ok, _app} = Chat.enable_site(scope, app)
    conn = log_in_account(conn, account)
    {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.id}")
    assert html =~ "embed.js"
    assert html =~ "floating chat bubble"
  end

  test "public chat events are rate limited per visitor", %{conn: conn, scope: scope, app: app} do
    {:ok, app} = Chat.enable_site(scope, app)
    {:ok, lv, _html} = live(conn, ~p"/site/#{app.site_token}")

    # Exhaust the per-site bucket (visitor-IP independent); the next send is refused.
    Enum.each(1..120, fn n ->
      FluxWeb.SiteRateLimit.allow?(app.site_token, "10.0.0.#{n}")
    end)

    html = lv |> form("#site-chat-form", %{"content" => "over the line"}) |> render_submit()
    assert html =~ "Too many requests"
    assert Chat.list_conversations(scope, app.id) == []
  end

  test "returning visitors resume their conversation via the session ref", %{
    conn: conn,
    scope: scope,
    app: app
  } do
    {:ok, app} = Chat.enable_site(scope, app)

    # First visit establishes the cookie and sends a message.
    conn = get(conn, ~p"/site/#{app.site_token}")
    {:ok, lv, _html} = live(conn)
    lv |> form("#site-chat-form", %{"content" => "remember me"}) |> render_submit()
    poll_until(lv, "You said: remember me", 50)
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"

    # Same conn (same session cookie): the conversation is restored.
    {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")
    assert html =~ "remember me"
    assert html =~ "You said: remember me"

    [conversation] = Chat.list_conversations(scope, app.id)
    assert conversation.end_user_ref =~ "web_"
  end

  test "visitors switch between their conversations", %{conn: conn, scope: scope, app: app} do
    {:ok, app} = Chat.enable_site(scope, app)

    conn = get(conn, ~p"/site/#{app.site_token}")
    {:ok, lv, _html} = live(conn)

    # First conversation.
    lv |> form("#site-chat-form", %{"content" => "first thread"}) |> render_submit()
    poll_until(lv, "You said: first thread", 50)
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"

    # Start over → second conversation.
    lv |> element("button[phx-click=start_over]") |> render_click()
    lv |> form("#site-chat-form", %{"content" => "second thread"}) |> render_submit()
    poll_until(lv, "You said: second thread", 50)
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"

    # Fresh mount shows the switcher; picking the first restores its messages.
    {:ok, lv, html} = live(conn, ~p"/site/#{app.site_token}")
    assert html =~ "conversation-switcher"

    [_newest, older] =
      Chat.visitor_conversations(
        scope,
        app.id,
        hd(Chat.list_conversations(scope, app.id)).end_user_ref
      )

    html =
      lv
      |> form("#conversation-switcher", %{"conversation-id" => older.id})
      |> render_change()

    # The older thread's messages render; the newer thread's do not (its
    # auto-title still shows in the switcher options).
    assert html =~ "You said: first thread"
    refute html =~ "You said: second thread"
  end

  test "site theme applies accent, title, and logo", %{
    conn: conn,
    scope: scope,
    app: app,
    account: account
  } do
    {:ok, app} = Chat.enable_site(scope, app)

    console = log_in_account(conn, account)
    {:ok, lv, _html} = live(console, ~p"/console/apps/#{app.id}")

    lv
    |> form("#site-theme-form", %{
      "accent" => "#ff5500",
      "title" => "Support Bot",
      "logo_url" => "https://cdn.example.com/logo.png"
    })
    |> render_submit()

    {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")
    assert html =~ "Support Bot"
    assert html =~ "#ff5500"
    assert html =~ "cdn.example.com/logo.png"

    # Malformed accents never reach the style block.
    {:ok, _} =
      Chat.update_app(scope, Chat.get_app(scope, app.id), %{
        "site_theme" => %{"accent" => "red; } body { display:none"}
      })

    {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")
    refute html =~ "display:none"
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
