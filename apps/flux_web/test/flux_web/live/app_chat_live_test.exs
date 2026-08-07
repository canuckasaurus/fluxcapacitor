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

  test "duplicate button clones the app configuration", %{conn: conn, app: app, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps")

    html =
      lv
      |> element(~s{#app-#{app.id} button[phx-click="duplicate"]})
      |> render_click()

    assert html =~ "UI Echo (copy)"

    copy = Enum.find(Chat.list_apps(scope), &(&1.name == "UI Echo (copy)"))
    assert copy.provider_plugin_id == app.provider_plugin_id
    refute copy.site_enabled
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

  test "assistant replies render markdown in tight bubbles", %{conn: conn, app: app} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    lv
    |> form("#chat-form", %{"content" => "give me **bold** and `code`"})
    |> render_submit()

    html = poll_until(lv, "chat-inline-code", 50)
    assert html =~ "markdown-chat"
    assert html =~ "<strong>bold</strong>"
    assert html =~ ~s(<code class="chat-inline-code">code</code>)

    # Batch-11 regression: bubble content hugs the tag — whitespace text
    # nodes inside a pre-wrap container render as blank lines.
    assert html =~ ~r/chat-bubble[^"]*"><span class="whitespace-pre-wrap">/

    # And the raw markdown is never double-rendered in the user bubble.
    assert html =~ "give me **bold** and `code`"

    # Let generation finalize so the stream task doesn't outlive the
    # test's DB sandbox ownership.
    refute poll_until_gone(lv, "animate-pulse", 50) =~ "animate-pulse"
  end

  test "the console resumes the latest conversation and switches back", %{
    conn: conn,
    app: app,
    scope: scope
  } do
    first = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, first, "first thread")
    assert_receive {:done, _}, 5_000

    second = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, second, "second thread")
    assert_receive {:done, _}, 5_000

    # Mount resumes the newest conversation, not a blank slate.
    {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")
    assert html =~ "You said: second thread"
    refute html =~ "You said: first thread"
    assert html =~ "conversation-switcher"

    # The switcher jumps to an older thread.
    html =
      lv
      |> form("#conversation-switcher", %{"conversation-id" => first.id})
      |> render_change()

    assert html =~ "You said: first thread"
    refute html =~ "You said: second thread"

    # New conversation clears the pane but keeps the list.
    html = lv |> element("button", "New conversation") |> render_click()
    refute html =~ "You said:"
    assert html =~ "conversation-switcher"
  end

  test "follow-up chips appear when the app opts in", %{conn: conn, app: app, scope: scope} do
    {:ok, _app} = Chat.update_app(scope, app, %{"suggest_followups" => true})

    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    lv
    |> form("#chat-form", %{"content" => "what next?"})
    |> render_submit()

    html = poll_until(lv, "followup-chips", 100)
    assert html =~ "followup-chips"
    # Echo-backed suggestions reflect the transcript.
    assert html =~ "You said:"

    # Clicking a chip sends it as the next message and clears the chips.
    html = lv |> element("#followup-chips button:first-of-type") |> render_click()
    refute html =~ "followup-chips"
  end

  test "conversations rename and delete from the switcher", %{
    conn: conn,
    app: app,
    scope: scope
  } do
    conversation = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "name me")
    assert_receive {:done, _}, 5_000

    {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")
    assert html =~ "name me"

    # Rename via the pencil → inline form.
    lv |> element("button[phx-click=start_rename]") |> render_click()
    html = lv |> form("#rename-form", %{"title" => "Naming ceremony"}) |> render_submit()
    assert html =~ "Naming ceremony"

    # Delete falls back to an empty pane (no conversations left).
    html = lv |> element("button[phx-click=delete_conversation]") |> render_click()
    refute html =~ "Naming ceremony"
    refute html =~ "conversation-switcher"
    assert Chat.console_conversations(scope, app.id) == []
  end

  test "creating an API key shows the raw token once", %{conn: conn, app: app} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}")

    html = lv |> form("#create-token-form", %{"lifetime" => ""}) |> render_submit()
    assert html =~ "app-"
    assert html =~ "Copy this key now"
    # Perpetual is a first-class choice…
    assert html =~ "never"

    # …and so is expiring: a 30-day key shows its date.
    html = lv |> form("#create-token-form", %{"lifetime" => "30"}) |> render_submit()
    expected = DateTime.utc_now() |> DateTime.add(30, :day) |> Calendar.strftime("%b %d, %Y")
    assert html =~ expected
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

  test "chat-app DSL imports on the Apps page and round-trips through export", %{
    conn: conn,
    scope: scope
  } do
    dsl = """
    app:
      name: Imported Helper
      description: A helpful bot
      mode: chat
    kind: app
    version: 0.3.1
    model_config:
      model:
        provider: langgenius/openai/openai
        name: gpt-4o
        completion_params:
          temperature: 0.4
      pre_prompt: You are terse and helpful.
      opening_statement: Hi! How can I help?
      suggested_questions:
        - What can you do?
      user_input_form:
        - text-input:
            label: Name
            variable: name
            required: true
    """

    {:ok, lv, _html} = live(conn, ~p"/console/apps")
    lv |> element("button", "Import DSL") |> render_click()

    assert {:error, {:live_redirect, %{to: "/console/apps/" <> app_id}}} =
             lv |> form("#app-import-form", %{"dsl" => dsl}) |> render_submit()

    app = Chat.get_app(scope, app_id)
    assert app.name == "Imported Helper"
    assert app.provider_plugin_id == "openai"
    assert app.model == "gpt-4o"
    assert app.system_prompt == "You are terse and helpful."
    assert app.opening_statement == "Hi! How can I help?"
    assert app.suggested_questions == ["What can you do?"]
    assert [%{"variable" => "name", "required" => true}] = app.input_form

    # Export → reimport preserves the essentials.
    exported = Flux.Workflows.DSL.export_app(app)
    assert {:ok, %{attrs: attrs}} = Flux.Workflows.DSL.parse_app(exported)
    assert attrs["name"] == "Imported Helper"
    assert attrs["opening_statement"] == "Hi! How can I help?"
    assert attrs["model"] == "gpt-4o"
  end

  test "monitor page lists conversations and expands messages", %{
    conn: conn,
    app: app,
    scope: scope
  } do
    conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_test"})
    {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "monitor me")
    assert_receive {:done, _final}, 5_000

    {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
    assert html =~ "web_test"

    # Usage rollup shows the assistant reply and its echo-provider tokens,
    # priced against the app's bound model when the table knows it.
    assert html =~ "Usage (last 14 days)"
    assert html =~ "Tokens out"

    Application.put_env(:flux, :model_pricing, %{"echo-1" => {1.0, 2.0}})
    on_exit(fn -> Application.delete_env(:flux, :model_pricing) end)

    {:ok, _lv, priced} = live(conn, ~p"/console/apps/#{app.id}/monitor")
    assert priced =~ "Est. cost"
    assert priced =~ "echo-1"

    # The conversation is auto-titled from its first question.
    html = lv |> element("button", "monitor me") |> render_click()
    assert html =~ "You said: monitor me"
  end

  test "quality trends roll up feedback and annotation hits", %{
    conn: conn,
    app: app,
    scope: scope
  } do
    conversation = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "good answer please")
    assert_receive {:done, liked}, 5_000
    {:ok, _} = Chat.set_feedback(scope, liked.id, :like)

    {:ok, _annotation} =
      Chat.create_annotation(scope, app, %{question: "canned?", answer: "Yes, canned."})

    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "canned?")
    assert_receive {:done, _annotated}, 5_000

    [today] = Chat.quality_stats(scope, app.id)
    assert today.replies == 2
    assert today.likes == 1
    assert today.dislikes == 0
    assert today.annotation_hits == 1

    {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
    assert html =~ "Quality (last 14 days)"
    assert html =~ "Annotation hits"
  end

  test "monitor search finds messages across conversations", %{
    conn: conn,
    app: app,
    scope: scope
  } do
    first = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, first, "the printer is on fire")
    assert_receive {:done, _}, 5_000

    second = Chat.create_conversation(scope, app)
    {:ok, _u, _a} = Chat.send_message(scope, app, second, "how do refunds work?")
    assert_receive {:done, _}, 5_000

    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}/monitor")

    html = lv |> form("#search-form", %{"query" => "printer"}) |> render_submit()
    assert html =~ "the printer is on fire"
    # The other conversation's messages stay out of the results (its
    # auto-title still shows in the conversation list below).
    refute html =~ "You said: how do refunds work"

    html = lv |> form("#search-form", %{"query" => "no such phrase"}) |> render_submit()
    assert html =~ "No messages matched."

    # SQL wildcards in the query are literals, not patterns.
    html = lv |> form("#search-form", %{"query" => "%"}) |> render_submit()
    assert html =~ "No messages matched."
  end

  test "annotations answer matching questions instantly", %{
    conn: conn,
    app: app,
    scope: scope
  } do
    conversation = Chat.create_conversation(scope, app)

    {:ok, _user, _assistant} =
      Chat.send_message(scope, app, conversation, "What is the refund policy?")

    assert_receive {:done, reply}, 5_000

    {:ok, _} = Chat.set_feedback(scope, reply.id, :like)

    # Promote via the monitor page's feedback card.
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
    html = lv |> element("button", "Save as annotation") |> render_click()
    assert html =~ "answer instantly"
    assert html =~ "What is the refund policy?"

    # A matching question (case/punctuation-insensitive) short-circuits
    # the model: annotation answer, zero token usage.
    {:ok, _user, _assistant} =
      Chat.send_message(scope, app, conversation, "what is the refund policy")

    assert_receive {:done, annotated}, 5_000
    assert annotated.content == String.trim(reply.content)
    assert annotated.usage["output_tokens"] == 0
    assert annotated.usage["annotation_id"]

    [annotation] = Chat.list_annotations(scope, app.id)
    assert annotation.hit_count == 1

    # Different questions still reach the model.
    {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "another question")
    assert_receive {:done, normal}, 5_000
    assert normal.content =~ "You said: another question"
    assert normal.usage["output_tokens"] == 12

    # Deleting the annotation restores model answers for the question.
    {:ok, _} = Chat.delete_annotation(scope, annotation.id)

    {:ok, _user, _assistant} =
      Chat.send_message(scope, app, conversation, "What is the refund policy?")

    assert_receive {:done, restored}, 5_000
    assert restored.content =~ "You said:"
  end

  test "fuzzy annotation matching answers near-duplicate questions", %{
    app: app,
    scope: scope
  } do
    {:ok, app} = Chat.update_app(scope, app, %{"annotation_threshold" => 0.6})

    {:ok, annotation} =
      Chat.create_annotation(scope, app, %{
        question: "What is the refund policy?",
        answer: "Refunds within 30 days."
      })

    # The question embedded at creation (echo embeddings are keyless).
    assert is_list(annotation.embedding)
    assert annotation.embedding_plugin_id == "echo"

    conversation = Chat.create_conversation(scope, app)

    # Same words, different order: not an exact normalized match, but
    # similar enough to clear the threshold.
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "refund policy: what is it?")
    assert_receive {:done, fuzzy}, 5_000
    assert fuzzy.content == "Refunds within 30 days."
    assert fuzzy.usage["annotation_id"] == annotation.id

    # An unrelated question falls through to the model.
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "weather in toledo today")
    assert_receive {:done, other}, 5_000
    assert other.content =~ "You said:"

    # Without a threshold only exact matches short-circuit.
    {:ok, app} = Chat.update_app(scope, app, %{"annotation_threshold" => nil})
    {:ok, _u, _a} = Chat.send_message(scope, app, conversation, "refund policy: what is it?")
    assert_receive {:done, exact_only}, 5_000
    assert exact_only.content =~ "You said:"
  end

  test "feedback review lists rated replies with their questions", %{
    conn: conn,
    app: app,
    scope: scope
  } do
    conversation = Chat.create_conversation(scope, app)
    {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "rate me well")
    assert_receive {:done, liked}, 5_000
    {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "rate me badly")
    assert_receive {:done, disliked}, 5_000

    {:ok, _} = Chat.set_feedback(scope, liked.id, :like)
    {:ok, _} = Chat.set_feedback(scope, disliked.id, :dislike)

    {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}/monitor")
    assert html =~ "2 rated replies"
    assert html =~ "rate me well"
    assert html =~ "👍 liked"
    assert html =~ "👎 disliked"

    # Filter to dislikes only: the liked reply drops out.
    html = lv |> element("#feedback-review button", "dislike") |> render_click()
    assert html =~ "1 rated replies"
    assert html =~ "rate me badly"
    refute html =~ "👍 liked"
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
