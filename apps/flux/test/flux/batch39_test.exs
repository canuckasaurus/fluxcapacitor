defmodule Flux.Batch39Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures
  import Swoosh.TestAssertions

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch39 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B39 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
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

  describe "idempotency store" do
    test "record, replay, prune", %{workspace: workspace} do
      assert Flux.Idempotency.lookup(workspace.id, "key-1") == nil

      :ok = Flux.Idempotency.record(workspace.id, "key-1", 200, ~s({"ok":true}))
      stored = Flux.Idempotency.lookup(workspace.id, "key-1")
      assert stored.response_status == 200
      assert stored.response_body =~ "ok"

      # A duplicate write quietly loses.
      :ok = Flux.Idempotency.record(workspace.id, "key-1", 500, "other")
      assert Flux.Idempotency.lookup(workspace.id, "key-1").response_status == 200

      # Old keys prune; fresh ones survive.
      tomorrow = DateTime.add(DateTime.utc_now(:second), 2, :day)
      :ok = Flux.Idempotency.prune(tomorrow)
      assert Flux.Idempotency.lookup(workspace.id, "key-1") == nil
    end
  end

  describe "email channel" do
    test "token lifecycle and inbound turn with mailed reply", %{scope: scope} do
      app = echo_app(scope)

      {:ok, app} = Chat.enable_email_channel(scope, app)
      assert String.starts_with?(app.email_channel_token, "emch_")
      assert {:ok, _found} = Chat.get_app_by_email_channel_token(app.email_channel_token)

      drain_emails()

      {:ok, conversation_id} =
        Chat.email_inbound(app, "Marty@Example.com", "Help", "where is the flux capacitor?")

      site_scope = Chat.site_scope(app)
      conversation = Chat.get_conversation(site_scope, conversation_id)
      assert conversation.end_user_ref == "email:marty@example.com"
      assert conversation.visitor_email == "Marty@Example.com"

      # The reply is mailed once generation settles.
      Process.sleep(1_500)

      assert_email_sent(fn email ->
        [{_name, to}] = email.to
        to == "Marty@Example.com" and email.subject =~ "Re: your message"
      end)

      # A second mail from the same sender lands in the same thread.
      {:ok, same_id} = Chat.email_inbound(app, "marty@example.com", nil, "follow-up")
      assert same_id == conversation_id
      Process.sleep(1_200)

      {:ok, disabled} = Chat.disable_email_channel(scope, app)
      assert disabled.email_channel_token == nil
    end
  end

  describe "app monthly budget" do
    test "estimated month spend past the cap answers quota_exceeded", %{
      scope: scope,
      workspace: workspace
    } do
      app = echo_app(scope, %{"monthly_cost_budget" => 0.01})

      # Under budget: works.
      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "cheap turn")

      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        case Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true) do
          %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
          done -> {:halt, done}
        end
      end)

      # Plant a priced reply worth ~$2.50 this month: over the 1¢ budget.
      Flux.Repo.insert!(%Flux.Chat.Message{
        workspace_id: workspace.id,
        conversation_id: conversation.id,
        role: :assistant,
        status: :completed,
        content: "expensive",
        usage: %{
          "model_used" => "gpt-4o",
          "input_tokens" => 1_000_000,
          "output_tokens" => 0
        }
      })

      assert Chat.month_cost_estimate(app) > 0.01
      assert {:error, :quota_exceeded} = Chat.send_message(scope, app, conversation, "one more?")
    end
  end

  describe "passkeys" do
    test "register, find, bump, delete", %{account: account} do
      assert Accounts.list_passkeys(account) == []

      cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => :crypto.strong_rand_bytes(32)}
      credential_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      {:ok, passkey} = Accounts.register_passkey(account, credential_id, cose_key, "work laptop")
      assert passkey.name == "work laptop"

      assert [%{name: "work laptop"}] = Accounts.list_passkeys(account)

      {:ok, found_account, found_passkey, found_key} = Accounts.find_passkey(credential_id)
      assert found_account.id == account.id
      assert found_key == cose_key

      {:ok, bumped} = Accounts.bump_passkey_sign_count(found_passkey, 7)
      assert bumped.sign_count == 7

      :ok = Accounts.delete_passkey(account, passkey.id)
      assert Accounts.list_passkeys(account) == []
      assert {:error, :not_found} = Accounts.find_passkey(credential_id)
    end
  end

  describe "member usage" do
    test "rolls up runs per starter", %{scope: scope, workspace: workspace} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Spend Flux"})

      for {who, tokens} <- [{"doc@example.com", 100}, {"doc@example.com", 50}, {"api:key1", 30}] do
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :succeeded,
          started_by: who,
          usage: %{"input_tokens" => tokens, "output_tokens" => 0, "estimated_cost_usd" => 0.001}
        })
      end

      rows = Flux.Usage.member_usage(scope)
      doc = Enum.find(rows, &(&1.who == "doc@example.com"))
      api = Enum.find(rows, &(&1.who == "api:key1"))

      assert doc.runs == 2
      assert doc.tokens == 150
      assert_in_delta doc.cost, 0.002, 0.0001
      assert api.runs == 1
    end
  end

  describe "away-mail on human reply" do
    defmodule AwayStub do
      def visitor_present?(_conversation_id), do: false
    end

    defmodule PresentStub do
      def visitor_present?(_conversation_id), do: true
    end

    test "mails the visitor only when they're gone", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_away"})

      {:ok, _updated} =
        Chat.set_visitor_identity(scope, conversation.id, "Doc", "doc@example.com")

      on_exit(fn -> Application.put_env(:flux, :site_presence, FluxWeb.SitePresence) end)

      Application.put_env(:flux, :site_presence, PresentStub)
      drain_emails()
      {:ok, _message} = Chat.human_reply(scope, conversation.id, "you still there?")
      refute_email_sent()

      Application.put_env(:flux, :site_presence, AwayStub)
      {:ok, _message} = Chat.human_reply(scope, conversation.id, "we found your answer")

      assert_email_sent(fn email ->
        [{_name, to}] = email.to
        to == "doc@example.com" and email.subject =~ "replied to you"
      end)
    end
  end

  describe "guardrail presets" do
    test "presets compile and append into the config", %{scope: scope} do
      presets = Flux.Guardrails.presets()
      assert Enum.count(presets) == 4

      for {_label, pattern} <- presets do
        assert {:ok, _regex} = Regex.compile(pattern, "i")
      end

      {_label, email_pattern} = List.first(presets)
      {:ok, _workspace} = Flux.Guardrails.configure(scope, email_pattern, "redact")

      workspace_id = Flux.Accounts.Scope.workspace_id(scope)
      assert %{patterns: [_one], action: "redact"} = Flux.Guardrails.config(workspace_id)

      assert Flux.Guardrails.redact_text(workspace_id, "mail doc@example.com now") =~ "•••"
    end
  end
end
