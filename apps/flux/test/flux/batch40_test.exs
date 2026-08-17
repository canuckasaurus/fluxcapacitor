defmodule Flux.Batch40Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Providers
  alias Flux.Providers.ProviderCredential

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch40 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B40 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp insert_credential(workspace_id, name, config, opts) do
    {:ok, encrypted} = Flux.Crypto.encrypt(workspace_id, Jason.encode!(config))

    Flux.Repo.insert!(%ProviderCredential{
      workspace_id: workspace_id,
      plugin_id: "openai",
      name: name,
      is_default: Keyword.get(opts, :default, false),
      balanced: Keyword.get(opts, :balanced, false),
      encrypted_config: encrypted
    })
  end

  describe "credential load balancing" do
    test "pooled keys rotate; without a pool the default wins", %{workspace: workspace} do
      insert_credential(workspace.id, "primary", %{"tag" => "primary"}, default: true)
      insert_credential(workspace.id, "pool-a", %{"tag" => "a"}, balanced: true)
      insert_credential(workspace.id, "pool-b", %{"tag" => "b"}, balanced: true)

      tags =
        for _turn <- 1..8, into: MapSet.new() do
          {:ok, %{"tag" => tag}} = Providers.fetch_config(workspace.id, "openai")
          tag
        end

      # Rotation across the pool; the unpooled default sits out.
      assert MapSet.equal?(tags, MapSet.new(["a", "b"]))

      # Failover order surfaces the whole pool.
      configs = Providers.fetch_configs(workspace.id, "openai")
      assert length(configs) == 2
    end

    test "failover moves to the next key on rate limits only", %{workspace: workspace} do
      insert_credential(workspace.id, "pool-a", %{"tag" => "a"}, balanced: true)
      insert_credential(workspace.id, "pool-b", %{"tag" => "b"}, balanced: true)

      # A 429 on the first key retries on the second.
      {:ok, tried} = Agent.start_link(fn -> [] end)

      result =
        Providers.invoke_with_failover(workspace.id, "openai", fn %{"tag" => tag} ->
          Agent.update(tried, &[tag | &1])

          case Agent.get(tried, &length/1) do
            1 -> {:error, "HTTP 429 rate limited"}
            _second -> {:ok, tag}
          end
        end)

      assert {:ok, _second_tag} = result
      assert Agent.get(tried, &length/1) == 2

      # A non-retryable error stops at the first key.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      assert {:error, "invalid request"} =
               Providers.invoke_with_failover(workspace.id, "openai", fn _config ->
                 Agent.update(counter, &(&1 + 1))
                 {:error, "invalid request"}
               end)

      assert Agent.get(counter, & &1) == 1
    end

    test "set_credential_balanced flags and audits", %{scope: scope, workspace: workspace} do
      credential = insert_credential(workspace.id, "default", %{"tag" => "solo"}, default: true)

      {:ok, updated} = Providers.set_credential_balanced(scope, credential.id, true)
      assert updated.balanced

      {:ok, updated} = Providers.set_credential_balanced(scope, credential.id, false)
      refute updated.balanced
    end
  end

  describe "external moderation endpoint" do
    setup %{scope: scope} do
      on_exit(fn -> Application.delete_env(:flux, :moderation_api_client) end)

      {:ok, _workspace} =
        Flux.Guardrails.configure_moderation_api(
          scope,
          "https://moderation.example.com/check",
          "block",
          "open"
        )

      %{workspace_id: Flux.Accounts.Scope.workspace_id(scope)}
    end

    test "flagged input blocks (and flag mode lets through)", %{
      scope: scope,
      workspace_id: workspace_id
    } do
      Application.put_env(:flux, :moderation_api_client, fn _url, payload ->
        {:ok, %{"flagged" => payload["text"] =~ "verboten", "reason" => "policy 7"}}
      end)

      assert Flux.Guardrails.check_input(workspace_id, "all fine here") == :ok

      assert Flux.Guardrails.check_input(workspace_id, "verboten topic") ==
               {:error, :guardrail}

      assert Enum.any?(
               Flux.Notifications.list(scope),
               &(&1.kind == "guardrail" and &1.title =~ "policy 7")
             )

      {:ok, _workspace} =
        Flux.Guardrails.configure_moderation_api(
          scope,
          "https://moderation.example.com/check",
          "flag",
          "open"
        )

      assert Flux.Guardrails.check_input(workspace_id, "verboten topic") == :ok
    end

    test "fail-open allows and fail-closed blocks when the endpoint is down", %{
      scope: scope,
      workspace_id: workspace_id
    } do
      Application.put_env(:flux, :moderation_api_client, fn _url, _payload ->
        {:error, :econnrefused}
      end)

      assert Flux.Guardrails.check_input(workspace_id, "anything") == :ok

      {:ok, _workspace} =
        Flux.Guardrails.configure_moderation_api(
          scope,
          "https://moderation.example.com/check",
          "block",
          "closed"
        )

      assert Flux.Guardrails.check_input(workspace_id, "anything") == {:error, :guardrail}
    end

    test "a non-http endpoint is refused; blank disables", %{
      scope: scope,
      workspace_id: workspace_id
    } do
      assert {:error, _message} =
               Flux.Guardrails.configure_moderation_api(scope, "ftp://nope", "block", "open")

      {:ok, _workspace} = Flux.Guardrails.configure_moderation_api(scope, "  ", "block", "open")
      assert Flux.Guardrails.moderation_api_config(workspace_id) == nil
    end
  end

  describe "canned replies" do
    test "save, upsert by title, delete", %{scope: scope} do
      assert Chat.list_canned_replies(scope) == []

      {:ok, _workspace} = Chat.save_canned_reply(scope, "greeting", "Hi! How can we help?")
      {:ok, _workspace} = Chat.save_canned_reply(scope, "refund", "Refunds take 3-5 days.")

      assert [%{"title" => "refund"}, %{"title" => "greeting"}] = Chat.list_canned_replies(scope)

      # Same title replaces the body instead of duplicating.
      {:ok, _workspace} = Chat.save_canned_reply(scope, "greeting", "Howdy!")
      replies = Chat.list_canned_replies(scope)
      assert length(replies) == 2
      assert Enum.find(replies, &(&1["title"] == "greeting"))["body"] == "Howdy!"

      assert {:error, :blank} = Chat.save_canned_reply(scope, "  ", "body")

      {:ok, _workspace} = Chat.delete_canned_reply(scope, "refund")
      assert [%{"title" => "greeting"}] = Chat.list_canned_replies(scope)
    end
  end

  describe "app budget alerts" do
    test "80 then 100, each once", %{scope: scope, workspace: workspace} do
      app = echo_app(scope, %{"monthly_cost_budget" => 3.0})
      conversation = Chat.create_conversation(scope, app)

      plant = fn ->
        Flux.Repo.insert!(%Flux.Chat.Message{
          workspace_id: workspace.id,
          conversation_id: conversation.id,
          role: :assistant,
          status: :completed,
          content: "expensive",
          usage: %{"model_used" => "gpt-4o", "input_tokens" => 1_000_000, "output_tokens" => 0}
        })
      end

      tick = %{DateTime.utc_now(:second) | minute: 5}

      warnings = fn ->
        Enum.count(Flux.Notifications.list(scope), &(&1.kind == "budget_warning"))
      end

      # Under 80%: silent.
      :ok = Chat.check_app_budget_alerts(tick)
      assert warnings.() == 0

      # ~$2.50 of a $3 budget: the 80% warning, exactly once.
      plant.()
      :ok = Chat.check_app_budget_alerts(tick)
      :ok = Chat.check_app_budget_alerts(tick)
      assert warnings.() == 1

      # ~$5.00: escalates to the 100% warning, exactly once more.
      plant.()
      :ok = Chat.check_app_budget_alerts(tick)
      :ok = Chat.check_app_budget_alerts(tick)
      assert warnings.() == 2

      # Off-minute ticks do nothing.
      :ok = Chat.check_app_budget_alerts(%{tick | minute: 6})
      assert warnings.() == 2
    end
  end

  describe "conversation assignment" do
    test "assign to any member; the list carries the assignee", %{
      scope: scope,
      account: account
    } do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      {:ok, assigned} = Chat.assign_handoff(scope, conversation.id, account.id)
      assert assigned.assigned_account.email == account.email

      assert [listed] = Chat.list_conversations(scope, app.id, 10)
      assert listed.assigned_account.id == account.id

      {:ok, released} = Chat.assign_handoff(scope, conversation.id, nil)
      assert released.assigned_account_id == nil
    end
  end

  describe "embed origins" do
    test "frame ancestors resolve from the app's origin list", %{scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      assert Chat.embed_frame_ancestors(app.site_token) == nil
      assert Chat.embed_frame_ancestors("site_nonexistent") == nil
      assert Chat.embed_frame_ancestors(nil) == nil

      {:ok, app} =
        Chat.update_app(scope, app, %{
          "embed_origins" => "https://www.example.com\nhttps://docs.example.com"
        })

      assert Chat.embed_frame_ancestors(app.site_token) ==
               ["https://www.example.com", "https://docs.example.com"]
    end
  end
end
