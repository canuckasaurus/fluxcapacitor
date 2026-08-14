defmodule FluxWeb.Batch34WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch34 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "flux-site passcode" do
    test "visitors are challenged, then let through", %{conn: conn, scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Gated Form"})

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
      {:ok, _version} = Workflows.publish(scope, workflow)
      {:ok, workflow} = Workflows.enable_site(scope, workflow)
      {:ok, workflow} = Workflows.set_site_passcode(scope, workflow, "88mph")

      {:ok, _lv, html} = live(conn, ~p"/site/flux/#{workflow.site_token}")
      assert html =~ "site-passcode"
      assert html =~ "Gated Form"

      right =
        post(conn, ~p"/site/flux/#{workflow.site_token}/passcode", %{"passcode" => "88mph"})

      assert redirected_to(right) == ~p"/site/flux/#{workflow.site_token}"

      {:ok, _lv, html} = live(right, ~p"/site/flux/#{workflow.site_token}")
      refute html =~ "site-passcode"
      assert html =~ "Gated Form"
    end
  end

  describe "feedback comment on the public site" do
    test "a rated reply takes a comment", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "FB Site",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, lv, _html} = live(conn, ~p"/site/#{app.site_token}")

      lv |> element("#site-chat-form") |> render_submit(%{"content" => "hello"})

      html = wait_for_reply(lv)
      assert html =~ "You said"

      site_scope = Chat.site_scope(app)
      [conversation] = Chat.visitor_conversations(site_scope, app.id, visitor_ref(lv))
      [_user, assistant] = Chat.list_messages(site_scope, conversation.id)

      lv
      |> element(~s(button[phx-value-message-id="#{assistant.id}"][phx-value-rating="dislike"]))
      |> render_click()

      html =
        lv
        |> element("#feedback-comment-#{assistant.id}")
        |> render_submit(%{"message_id" => assistant.id, "comment" => "too vague"})

      assert html =~ "Thanks for the feedback."

      reloaded = Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true)
      assert reloaded.feedback == :dislike
      assert reloaded.feedback_comment == "too vague"
    end
  end

  describe "PATCH /v1/datasets/:id" do
    test "updates settings over the API", %{conn: conn, scope: scope} do
      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "API KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, _token, raw} = Chat.create_workspace_token(scope)

      assert %{"result" => "success"} =
               conn
               |> put_req_header("authorization", "Bearer #{raw}")
               |> patch(~p"/v1/datasets/#{dataset.id}", %{
                 "chunk_size" => 800,
                 "retrieval_mode" => "keyword",
                 "qa_indexing" => true
               })
               |> json_response(200)

      updated = RAG.get_dataset(scope, dataset.id)
      assert updated.chunk_size == 800
      assert updated.retrieval_mode == :keyword
      assert updated.qa_indexing == true

      assert build_conn()
             |> put_req_header("authorization", "Bearer #{raw}")
             |> patch(~p"/v1/datasets/#{dataset.id}", %{"chunk_size" => 1})
             |> json_response(400)
    end
  end

  describe "/v1 feedback content param" do
    test "the compat feedbacks endpoint stores the comment", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "FB API",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "api rate me")

      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        case Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true) do
          %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
          done -> {:halt, done}
        end
      end)

      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> post(~p"/v1/messages/#{assistant.id}/feedbacks", %{
               "rating" => "dislike",
               "content" => "hallucinated a date"
             })
             |> json_response(200)

      reloaded = Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true)
      assert reloaded.feedback_comment == "hallucinated a date"
    end
  end

  defp wait_for_reply(lv) do
    Enum.reduce_while(1..50, "", fn _try, _acc ->
      html = render(lv)

      if html =~ "You said" do
        {:halt, html}
      else
        Process.sleep(100)
        {:cont, html}
      end
    end)
  end

  defp visitor_ref(lv) do
    # The site assigns a random web_… ref per (unconnected) session; read
    # it back through the only conversation's end_user_ref after sending.
    :sys.get_state(lv.pid).socket.assigns.end_user_ref
  end
end
