defmodule FluxWeb.Batch37WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch37 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B37 Web App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end

  describe "GET /v1/usage" do
    test "returns daily totals under a workspace token", %{conn: conn, scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "usage ping")

      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        case Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true) do
          %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
          done -> {:halt, done}
        end
      end)

      {:ok, _token, raw} = Chat.create_workspace_token(scope)

      body =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get(~p"/v1/usage?days=7")
        |> json_response(200)

      assert body["period_days"] == 7
      assert [today | _rest] = body["data"]
      assert today["messages"] >= 1
      assert today["total_tokens"] > 0
      assert is_number(today["estimated_cost_usd"])
    end
  end

  describe "API citations" do
    test "blocking chat responses carry retriever_resources metadata", %{
      conn: conn,
      scope: scope
    } do
      app = echo_app(scope)
      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      body =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/v1/chat-messages", %{
          "query" => "cite me",
          "response_mode" => "blocking"
        })
        |> json_response(200)

      # A plain chat app has no knowledge nodes, so the list is empty —
      # what matters is the reference-shaped key being present.
      assert body["metadata"]["retriever_resources"] == []
      assert is_map(body["metadata"]["usage"])
    end
  end

  describe "SCIM Groups" do
    setup %{scope: scope} do
      {:ok, raw} = Accounts.enable_scim(scope)
      %{scim_auth: "Bearer #{raw}"}
    end

    test "list, show, and role assignment via PATCH", %{
      conn: conn,
      scim_auth: auth,
      workspace: workspace,
      account: owner
    } do
      member = account_fixture()
      {:ok, _membership} = Accounts.scim_provision(workspace, member.email)

      conn = put_req_header(conn, "authorization", auth)

      body = conn |> get(~p"/scim/v2/Groups") |> json_response(200)
      assert body["totalResults"] == 4
      ids = Enum.map(body["Resources"], & &1["id"])
      assert Enum.sort(ids) == ["admin", "dataset_operator", "editor", "normal"]

      # The provisioned member starts in the normal group.
      normal = conn |> get(~p"/scim/v2/Groups/normal") |> json_response(200)
      assert Enum.any?(normal["members"], &(&1["value"] == member.id))

      # Okta-style add: value list.
      editor =
        conn
        |> patch(~p"/scim/v2/Groups/editor", %{
          "Operations" => [
            %{"op" => "add", "path" => "members", "value" => [%{"value" => member.id}]}
          ]
        })
        |> json_response(200)

      assert Enum.any?(editor["members"], &(&1["value"] == member.id))
      assert Accounts.scim_find_member(workspace.id, member.id).role == :editor

      # Entra-style remove: filtered path. Back to normal.
      removed =
        conn
        |> patch(~p"/scim/v2/Groups/editor", %{
          "Operations" => [%{"op" => "remove", "path" => ~s(members[value eq "#{member.id}"])}]
        })
        |> json_response(200)

      assert removed["members"] == []
      assert Accounts.scim_find_member(workspace.id, member.id).role == :normal

      # The owner never moves.
      conn
      |> patch(~p"/scim/v2/Groups/editor", %{
        "Operations" => [
          %{"op" => "add", "path" => "members", "value" => [%{"value" => owner.id}]}
        ]
      })
      |> json_response(200)

      assert Accounts.scim_find_member(workspace.id, owner.id).role == :owner

      assert conn |> get(~p"/scim/v2/Groups/board") |> json_response(404)
    end
  end

  describe "workspace default locale" do
    test "fills in when the browser doesn't say", %{conn: conn, scope: scope, account: account} do
      {:ok, _workspace} = Accounts.set_workspace_locale(scope, "de")

      conn = conn |> log_in_account(account) |> get(~p"/console/apps")
      assert get_session(conn, :locale) == "de"
    end

    test "an explicit choice still wins", %{conn: conn, scope: scope, account: account} do
      {:ok, _workspace} = Accounts.set_workspace_locale(scope, "de")

      conn = conn |> log_in_account(account) |> get(~p"/console/apps?locale=fr")
      assert get_session(conn, :locale) == "fr"
    end
  end

  describe "audit actor filter" do
    test "the select narrows the table", %{conn: conn, scope: scope, account: account} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Audited Flux"})
      {:ok, _version} = Flux.Workflows.publish(scope, workflow)

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/audit")

      assert html =~ "Everyone"
      assert html =~ "workflow.publish"

      # Filtering by the acting member keeps the entry…
      html =
        lv
        |> element("#audit-filter")
        |> render_change(%{"from" => "", "to" => "", "actor" => account.id})

      assert html =~ "workflow.publish"

      # …and a date window in the past clears it.
      html =
        lv
        |> element("#audit-filter")
        |> render_change(%{"from" => "2000-01-01", "to" => "2000-01-02", "actor" => account.id})

      refute html =~ "workflow.publish"
    end
  end

  describe "document download" do
    test "streams the stored content", %{conn: conn, scope: scope, account: account} do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "DL KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, document} =
        RAG.add_document(scope, dataset, %{name: "manual.md", content: "flux the capacitor"})

      conn =
        conn
        |> log_in_account(account)
        |> get(~p"/console/knowledge/#{dataset.id}/documents/#{document.id}/download")

      assert response(conn, 200) == "flux the capacitor"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "manual.md"
    end
  end

  describe "message edit in the console chat" do
    test "edit and resend rewrites the turn", %{conn: conn, scope: scope, account: account} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)
      {:ok, user_message, assistant} = Chat.send_message(scope, app, conversation, "howdy")

      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        case Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true) do
          %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
          done -> {:halt, done}
        end
      end)

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")

      assert html =~ "Edit"

      lv
      |> element(~s(button[phx-click="start_edit_message"]))
      |> render_click()

      lv
      |> element("#edit-form-#{user_message.id}")
      |> render_submit(%{"content" => "howdy partner"})

      assert render(lv) =~ "howdy partner"

      # The edited turn replaced the original — still one user message.
      [%{role: :user, content: content} | _rest] = Chat.list_messages(scope, conversation.id)
      assert content == "howdy partner"
    end
  end

  describe "snippet picker" do
    test "appends library content to the system prompt draft", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      {:ok, _snippet} = Flux.Prompts.upsert(scope, "tone", "Answer in a warm tone.")
      app = echo_app(scope, %{"system_prompt" => "Base persona."})

      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.id}")

      assert html =~ "Insert a library snippet"

      [snippet] = Flux.Prompts.list(scope)

      lv
      |> element("#snippet-insert-form")
      |> render_change(%{"snippet" => snippet.id})

      assert render(lv) =~ "Answer in a warm tone."

      lv
      |> element("#system-prompt-form")
      |> render_submit(%{"system_prompt" => "Base persona.\n\nAnswer in a warm tone."})

      reloaded = Chat.get_app(scope, app.id)
      assert reloaded.system_prompt =~ "warm tone"
    end
  end

  describe "site transcript email" do
    test "the button mails the visitor", %{conn: conn, scope: scope} do
      app = echo_app(scope, %{"collect_visitor_info" => true})
      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, lv, _html} = live(conn, ~p"/site/#{app.site_token}")

      lv
      |> element("#visitor-identity-form")
      |> render_submit(%{"name" => "Doc", "email" => "doc@example.com"})

      lv
      |> element("#site-chat-form")
      |> render_submit(%{"content" => "remember this"})

      site_scope = Chat.site_scope(app)
      [conversation] = Flux.Repo.all(Flux.Repo.scoped(Flux.Chat.Conversation, site_scope))

      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        streaming? =
          Flux.Repo.all(Flux.Repo.scoped(Flux.Chat.Message, site_scope))
          |> Enum.any?(&(&1.status == :streaming))

        (streaming? && Process.sleep(100) && {:cont, nil}) || {:halt, :done}
      end)

      assert conversation.visitor_email == "doc@example.com"
      drain_emails()

      lv
      |> element("#email-transcript")
      |> render_click()

      assert_email_sent(fn email ->
        [{_name, to}] = email.to
        to == "doc@example.com"
      end)
    end
  end

  describe "web push settings" do
    test "subscribe and unsubscribe through the settings LiveView", %{
      conn: conn,
      account: account
    } do
      conn = log_in_account(conn, account)
      {:ok, lv, html} = live(conn, ~p"/accounts/settings")

      assert html =~ "Enable browser notifications"

      {client_public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

      subscription = %{
        "endpoint" => "https://push.example.com/reg/1",
        "keys" => %{
          "p256dh" => Base.url_encode64(client_public, padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      }

      html = render_hook(lv, "push_subscribed", %{"subscription" => subscription})
      assert html =~ "Disable browser notifications"
      assert Flux.WebPush.subscribed?(account)

      html =
        render_hook(lv, "push_unsubscribed", %{"endpoint" => "https://push.example.com/reg/1"})

      assert html =~ "Enable browser notifications"
      refute Flux.WebPush.subscribed?(account)
    end
  end

  describe "fire now" do
    test "the editor button starts a trigger run", %{conn: conn, scope: scope, account: account} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Manual Fire"})
      {:ok, _version} = Flux.Workflows.publish(scope, workflow)

      {:ok, trigger} =
        Flux.Workflows.create_trigger(scope, workflow, %{
          "type" => "schedule",
          "interval_minutes" => 60
        })

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

      lv |> element("button[phx-click=toggle_triggers]") |> render_click()

      lv
      |> element(~s(button[phx-click="fire_trigger"][phx-value-trigger-id="#{trigger.id}"]))
      |> render_click()

      runs = Flux.Workflows.list_workspace_runs(scope, %{})
      assert Enum.any?(runs, &(&1.run.started_by == "trigger:schedule"))

      # Let async runs settle before teardown.
      Process.sleep(300)
    end
  end
end
