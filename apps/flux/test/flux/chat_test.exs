defmodule Flux.ChatTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Providers

  # Core tests run against Flux.FakeRuntime (see test_helper.exs); the real
  # runtime path is exercised end-to-end by the flux_web suites.
  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Chat WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Echo App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "system_prompt" => "You echo."
      })

    %{scope: scope, app: app, workspace: workspace}
  end

  test "send_message streams chunks and persists the final message", %{scope: scope, app: app} do
    conversation = Chat.create_conversation(scope, app)

    {:ok, user_message, assistant_message} =
      Chat.send_message(scope, app, conversation, "hello flux")

    assert user_message.role == :user
    assert assistant_message.status == :streaming

    assert_receive {:chunk, _delta}, 2_000
    assert_receive {:done, final}, 5_000

    assert final.id == assistant_message.id
    assert final.status == :completed
    assert final.content =~ "You said: hello flux"
    assert final.usage["output_tokens"] == 12

    messages = Chat.list_messages(scope, conversation.id)
    assert length(messages) == 2
  end

  test "conversation history feeds the next turn", %{scope: scope, app: app} do
    conversation = Chat.create_conversation(scope, app)

    {:ok, _, _} = Chat.send_message(scope, app, conversation, "first")
    assert_receive {:done, _}, 5_000

    {:ok, _, _} = Chat.send_message(scope, app, conversation, "second")
    assert_receive {:done, final}, 5_000

    # Echo answers the LAST user message — proves history ordering held.
    assert final.content =~ "You said: second"
    assert length(Chat.list_messages(scope, conversation.id)) == 4
  end

  test "apps are workspace-scoped", %{app: app} do
    other = account_fixture()
    {:ok, _} = Accounts.create_workspace(other, %{name: "Other"})
    other_scope = Accounts.scope_for(other)

    assert Chat.list_apps(other_scope) == []
    assert {:error, :not_found} = Chat.get_app(other_scope, app.id)
  end

  test "create_app requires app_create_and_management", %{scope: scope, app: app} do
    member = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: app.workspace_id,
        account_id: member.id,
        role: :normal
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, app.workspace_id)
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} =
             Chat.create_app(member_scope, %{
               "name" => "Nope",
               "provider_plugin_id" => "echo",
               "model" => "echo-1"
             })

    # But an editor-created scope (the owner here) can — sanity check.
    assert {:ok, _} =
             Chat.create_app(scope, %{
               "name" => "Second",
               "provider_plugin_id" => "echo",
               "model" => "echo-1"
             })
  end

  test "api tokens roundtrip and resolve to the app", %{scope: scope, app: app} do
    {:ok, token, raw} = Chat.create_api_token(scope, app)
    assert String.starts_with?(raw, "app-")
    assert token.prefix =~ "app-"

    assert {:ok, resolved_app, _token} = Chat.fetch_app_by_token(raw)
    assert resolved_app.id == app.id

    assert {:error, :invalid_token} = Chat.fetch_app_by_token("app-bogus")
    assert {:error, :invalid_token} = Chat.fetch_app_by_token("nonsense")

    {:ok, _} = Chat.revoke_api_token(scope, token.id)
    assert {:error, :invalid_token} = Chat.fetch_app_by_token(raw)
  end

  test "stopping mid-stream persists the streamed prefix", %{scope: scope} do
    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Drip App",
        "provider_plugin_id" => "drip",
        "model" => "echo-1"
      })

    conversation = Chat.create_conversation(scope, app)
    {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "go")

    # Wait until the prefix has streamed, then stop while the provider hangs.
    assert_receive {:chunk, "Dripped "}, 2_000
    assert_receive {:chunk, "prefix"}, 2_000

    assert {:ok, stopped} = Chat.stop_generation(scope, assistant.id)
    assert stopped.status == :stopped
    assert stopped.content == "Dripped prefix"
  end

  test "available_models includes keyless echo without credentials", %{scope: scope} do
    models = Providers.available_models(scope)
    assert Enum.any?(models, &(&1.plugin_id == "echo" and &1.model.name == "echo-1"))
    refute Enum.any?(models, &(&1.plugin_id == "openai"))
  end
end
