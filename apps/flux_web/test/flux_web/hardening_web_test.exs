defmodule FluxWeb.HardeningWebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Hardening Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  defp echo_app(scope, name) do
    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => name,
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    app
  end

  describe "app-token cross-tenant isolation" do
    test "an app A token can't rename or delete app B's conversation", %{
      conn: conn,
      scope: scope
    } do
      app_a = echo_app(scope, "A")
      app_b = echo_app(scope, "B")

      convo_b = Chat.create_conversation(scope, app_b, %{title: "B's thread"})

      {:ok, _token, raw} = Chat.create_api_token(scope, app_a)
      conn = put_req_header(conn, "authorization", "Bearer #{raw}")

      # Rename attempt across apps → 404, and the title is untouched.
      assert conn
             |> post(~p"/v1/conversations/#{convo_b.id}/name", %{"name" => "hijacked"})
             |> json_response(404)

      assert Chat.get_conversation(scope, convo_b.id).title == "B's thread"

      # Delete attempt across apps → 404, still present.
      assert conn
             |> delete(~p"/v1/conversations/#{convo_b.id}")
             |> json_response(404)

      refute Chat.get_conversation(scope, convo_b.id).deleted_at
    end

    test "an app A token can't rate app B's message", %{conn: conn, scope: scope, workspace: ws} do
      app_a = echo_app(scope, "A")
      app_b = echo_app(scope, "B")
      convo_b = Chat.create_conversation(scope, app_b)

      message_b =
        Flux.Repo.insert!(%Flux.Chat.Message{
          workspace_id: ws.id,
          conversation_id: convo_b.id,
          role: :assistant,
          status: :completed,
          content: "b"
        })

      {:ok, _token, raw} = Chat.create_api_token(scope, app_a)

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> post(~p"/v1/messages/#{message_b.id}/feedbacks", %{"rating" => "like"})
             |> json_response(404)

      refute Flux.Repo.get!(Flux.Chat.Message, message_b.id, skip_workspace_guard: true).feedback
    end

    test "an app A token CAN act on its own conversation", %{conn: conn, scope: scope} do
      app_a = echo_app(scope, "A")
      convo_a = Chat.create_conversation(scope, app_a, %{title: "mine"})

      {:ok, _token, raw} = Chat.create_api_token(scope, app_a)

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> post(~p"/v1/conversations/#{convo_a.id}/name", %{"name" => "renamed"})
             |> json_response(200)

      assert Chat.get_conversation(scope, convo_a.id).title == "renamed"
    end
  end

  describe "inbox permission gate" do
    test "a read-only member is bounced from the inbox", %{conn: conn, workspace: workspace} do
      member = account_fixture(%{email: "ro-#{System.unique_integer([:positive])}@example.com"})
      {:ok, _membership} = Accounts.scim_provision(workspace, member.email)

      conn = log_in_account(conn, member)

      assert {:error, {:live_redirect, %{to: "/console"}}} = live(conn, ~p"/console/inbox")
    end
  end

  describe "/v1 message pagination" do
    test "the messages endpoint caps its payload", %{conn: conn, scope: scope, workspace: ws} do
      app = echo_app(scope, "A")
      conversation = Chat.create_conversation(scope, app)

      for n <- 1..30 do
        Flux.Repo.insert!(%Flux.Chat.Message{
          workspace_id: ws.id,
          conversation_id: conversation.id,
          role: :user,
          status: :completed,
          content: "msg #{n}"
        })
      end

      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      body =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get(~p"/v1/messages?conversation_id=#{conversation.id}&limit=5")
        |> json_response(200)

      assert length(body["data"]) == 5
    end
  end
end
