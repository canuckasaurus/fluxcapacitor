defmodule Flux.Batch44Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Providers

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch44 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B44 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp refresh_scope(scope) do
    workspace = Flux.Repo.get!(Flux.Accounts.Workspace, Flux.Accounts.Scope.workspace_id(scope))
    %{scope | workspace: workspace}
  end

  describe "model allowlist" do
    test "restricts pickers and app saves; clearing restores everything", %{
      scope: scope,
      workspace: workspace
    } do
      # Unrestricted: the fake runtime's three keyless echo variants list.
      plugins = for %{plugin_id: pid} <- Providers.available_models(scope), do: pid
      assert "echo" in plugins
      assert "slow_echo" in plugins

      {:ok, _workspace} = Accounts.set_model_allowlist(scope, ["echo|echo-1"])

      assert [%{plugin_id: "echo"}] = Providers.available_models(scope)

      assert Providers.model_allowed?(workspace.id, "echo", "echo-1")
      refute Providers.model_allowed?(workspace.id, "slow_echo", "echo-1")

      # App writes refuse disallowed models — pickers aren't the only gate.
      assert {:error, :model_not_allowed} =
               Chat.create_app(scope, %{
                 "name" => "Sneaky",
                 "provider_plugin_id" => "slow_echo",
                 "model" => "echo-1"
               })

      app = echo_app(scope)

      assert {:error, :model_not_allowed} =
               Chat.update_app(scope, app, %{
                 "provider_plugin_id" => "slow_echo",
                 "model" => "echo-1"
               })

      # Empty clears the restriction.
      {:ok, _workspace} = Accounts.set_model_allowlist(scope, [])
      assert Accounts.model_allowlist(workspace.id) == nil

      assert {:ok, _app} =
               Chat.update_app(scope, app, %{
                 "provider_plugin_id" => "slow_echo",
                 "model" => "echo-1"
               })
    end
  end

  describe "workspace suspension" do
    test "runs and chat refuse while suspended; unsuspend restores", %{
      scope: scope,
      workspace: workspace
    } do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      {:ok, _workspace} = Accounts.suspend_workspace(workspace.id)
      assert Accounts.workspace_suspended?(workspace.id)

      assert {:error, :workspace_suspended} =
               Chat.send_message(scope, app, conversation, "anyone?")

      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Suspended Flux"})

      assert {:error, :workspace_suspended} =
               Flux.Workflows.start_run(scope, workflow, %{"query" => "hi"})

      {:ok, _workspace} = Accounts.unsuspend_workspace(workspace.id)
      refute Accounts.workspace_suspended?(workspace.id)
      assert {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "back!")
    end
  end

  describe "per-app guardrail overrides" do
    test "off skips patterns, extra adds the app's own", %{scope: scope} do
      {:ok, _workspace} = Flux.Guardrails.configure(scope, "forbidden-word", "block")

      inherit_app = echo_app(scope, %{"name" => "Inherit"})
      conversation = Chat.create_conversation(scope, inherit_app)

      assert {:error, :guardrail} =
               Chat.send_message(scope, inherit_app, conversation, "a forbidden-word here")

      # Off: the workspace pattern no longer blocks this app.
      {:ok, off_app} = Chat.set_app_guardrails(scope, echo_app(scope, %{"name" => "Off"}), "off")
      off_conversation = Chat.create_conversation(scope, off_app)

      assert {:ok, _user, _assistant} =
               Chat.send_message(scope, off_app, off_conversation, "a forbidden-word here")

      # Extra: the app's own pattern blocks on top of the workspace's.
      {:ok, extra_app} =
        Chat.set_app_guardrails(
          scope,
          echo_app(scope, %{"name" => "Extra"}),
          "extra",
          "internal-codename"
        )

      extra_conversation = Chat.create_conversation(scope, extra_app)

      assert {:error, :guardrail} =
               Chat.send_message(scope, extra_app, extra_conversation, "the internal-codename!")

      assert {:error, :guardrail} =
               Chat.send_message(scope, extra_app, extra_conversation, "a forbidden-word too")

      # Bad regexes and empty extra sets are refused.
      assert {:error, {:invalid_pattern, _pattern}} =
               Chat.set_app_guardrails(scope, extra_app, "extra", "([broken")

      assert {:error, :patterns_required} =
               Chat.set_app_guardrails(scope, extra_app, "extra", "  ")
    end
  end

  describe "AI-drafted replies" do
    test "drafts from conversation context via the app's model", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)
      {:ok, _message} = Chat.human_reply(scope, conversation.id, "How can we help?")

      assert {:ok, draft} = Chat.draft_reply(scope, conversation.id)
      assert is_binary(draft) and draft != ""
    end
  end

  describe "auto-resolve idle conversations" do
    test "resolves past the window, leaves fresh ones open", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _workspace} = Accounts.set_auto_resolve_days(scope, 7)

      app = echo_app(scope)
      stale = Chat.create_conversation(scope, app, %{title: "Stale"})
      fresh = Chat.create_conversation(scope, app, %{title: "Fresh"})

      old = DateTime.add(DateTime.utc_now(:second), -10, :day)

      Flux.Repo.insert!(%Flux.Chat.Message{
        workspace_id: workspace.id,
        conversation_id: stale.id,
        role: :user,
        content: "old question",
        inserted_at: old,
        updated_at: old
      })

      Flux.Repo.insert!(%Flux.Chat.Message{
        workspace_id: workspace.id,
        conversation_id: fresh.id,
        role: :user,
        content: "new question"
      })

      tick = %{DateTime.utc_now(:second) | hour: 4, minute: 15}
      :ok = Chat.auto_resolve_idle(tick)

      assert Chat.get_conversation(scope, stale.id).resolved_at != nil
      assert Chat.get_conversation(scope, fresh.id).resolved_at == nil

      # Off-schedule ticks do nothing.
      :ok = Chat.auto_resolve_idle(%{tick | minute: 16})
    end
  end

  describe "pending-work inbox" do
    test "paused runs list with their pause kind", %{scope: scope, workspace: workspace} do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Waiting Flux"})

      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :paused,
        snapshot: %{"node_id" => "ask", "prompt" => "Approve the draft?"}
      })

      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :paused,
        snapshot: %{"node_id" => "form", "prompt" => %{"questions" => [%{"name" => "q"}]}}
      })

      entries = Flux.Workflows.list_paused_runs(scope)
      assert length(entries) == 2
      kinds = Enum.map(entries, & &1.waiting_on) |> Enum.sort()
      assert kinds == ["human input", "interview"]
      assert Enum.all?(entries, &(&1.workflow_name == "Waiting Flux"))
    end
  end

  describe "provider rate caps" do
    test "the cap refuses past N calls a minute; uncapped flows free", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _workspace} = Providers.set_provider_rate_cap(scope, "echo", 2)
      assert Providers.provider_rate_cap(workspace.id, "echo") == 2

      call = fn ->
        Providers.invoke_with_failover(workspace.id, "echo", fn _credentials -> {:ok, :sent} end)
      end

      assert {:ok, :sent} = call.()
      assert {:ok, :sent} = call.()
      assert {:error, message} = call.()
      assert message =~ "capped at 2"

      # Another provider id has its own bucket.
      assert {:ok, :sent} =
               Providers.invoke_with_failover(workspace.id, "echo@other", fn _credentials ->
                 {:ok, :sent}
               end)

      {:ok, _workspace} = Providers.set_provider_rate_cap(scope, "echo", nil)
      assert Providers.provider_rate_cap(workspace.id, "echo") == nil
    end
  end

  describe "toolset re-import" do
    @spec_v1 """
    {"openapi": "3.0.0", "info": {"title": "Mini"},
     "servers": [{"url": "https://mini.example.com"}],
     "paths": {"/a": {"get": {"operationId": "opA"}},
               "/b": {"get": {"operationId": "opB"}}}}
    """

    @spec_v2 """
    {"openapi": "3.0.0", "info": {"title": "Mini"},
     "servers": [{"url": "https://mini.example.com"}],
     "paths": {"/a": {"get": {"operationId": "opA"}},
               "/c": {"get": {"operationId": "opC"}},
               "/d": {"get": {"operationId": "opD"}}}}
    """

    test "operations refresh, auth survives, pasted-only needs a paste", %{scope: scope} do
      {:ok, toolset} = Flux.Tools.create_toolset(scope, "Mini", @spec_v1)

      {:ok, toolset} =
        Flux.Tools.put_auth(scope, toolset, %{
          "type" => "api_key",
          "in" => "header",
          "name" => "X-Key",
          "value" => "sk-secret"
        })

      {:ok, updated, diff} = Flux.Tools.reimport_toolset(scope, toolset, @spec_v2)
      assert diff == %{added: 2, removed: 1}

      operation_ids = Enum.map(updated.operations, & &1["operation_id"]) |> Enum.sort()
      assert operation_ids == ["opA", "opC", "opD"]

      # Auth survived the refresh.
      assert updated.encrypted_auth != nil

      # A pasted toolset with no source URL can't re-import from nothing.
      assert {:error, :no_source} = Flux.Tools.reimport_toolset(scope, updated, nil)
    end
  end

  test "console IP allowlist toggle round-trips", %{scope: scope} do
    refute Accounts.console_ip_allowlist?(scope)
    {:ok, _workspace} = Accounts.set_console_ip_allowlist(scope, true)
    assert Accounts.console_ip_allowlist?(refresh_scope(scope))
    {:ok, _workspace} = Accounts.set_console_ip_allowlist(refresh_scope(scope), false)
    refute Accounts.console_ip_allowlist?(refresh_scope(scope))
  end
end
