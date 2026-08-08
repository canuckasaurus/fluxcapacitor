defmodule Flux.Batch20Test do
  @moduledoc "Batch-20 context features: redact, handoff, labels, playground, archive, cost report."
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Guardrails

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "B20 WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "B20 App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{account: account, scope: scope, app: app, workspace: workspace}
  end

  describe "guardrail redact mode" do
    test "masks chat input and reply instead of refusing", %{
      scope: scope,
      app: app,
      workspace: workspace
    } do
      {:ok, _} = Guardrails.configure(scope, "\\b\\d{3}-\\d{2}-\\d{4}\\b", "redact")

      conversation = Chat.create_conversation(scope, app)

      {:ok, user, _assistant} =
        Chat.send_message(scope, app, conversation, "my ssn is 123-45-6789")

      assert_receive {:done, final}, 5_000

      # Stored user message, the model's view, and the echoed reply are all masked.
      assert user.content == "my ssn is •••"
      assert final.content =~ "You said: my ssn is •••"
      refute final.content =~ "123-45-6789"

      # Run inputs mask too.
      redacted =
        Guardrails.maybe_redact_inputs(workspace.id, %{"q" => "ssn 123-45-6789", "n" => 5})

      assert redacted == %{"q" => "ssn •••", "n" => 5}

      # The team was told (guardrail notifications fired).
      assert Enum.any?(Flux.Notifications.list(scope), &(&1.kind == "guardrail"))
    end
  end

  describe "human handoff and labels" do
    test "flag → queue → human reply broadcast → flag cleared", %{scope: scope, app: app} do
      conversation = Chat.create_conversation(scope, app)
      {:ok, flagged} = Chat.request_handoff(scope, app, conversation.id)
      assert flagged.handoff_requested_at != nil

      assert [%{id: queued_id}] = Chat.handoff_queue(scope, app.id)
      assert queued_id == conversation.id
      assert Enum.any?(Flux.Notifications.list(scope), &(&1.kind == "handoff"))

      Chat.subscribe_conversation(conversation.id)

      {:ok, message} =
        Chat.human_reply(scope, conversation.id, "A real person here — how can I help?")

      assert message.role == :assistant
      assert message.usage["human"] == true
      assert_receive {:human_reply, %{id: broadcast_id}}, 1_000
      assert broadcast_id == message.id

      assert Chat.handoff_queue(scope, app.id) == []
    end

    test "labels set, dedupe, and list across the app", %{scope: scope, app: app} do
      conversation = Chat.create_conversation(scope, app)

      {:ok, labeled} =
        Chat.set_conversation_labels(scope, conversation.id, ["vip", " billing ", "vip", ""])

      assert labeled.labels == ["vip", "billing"]
      assert Chat.conversation_labels(scope, app.id) == ["billing", "vip"]
    end
  end

  describe "playground" do
    test "runs a prompt against a model with timing and cost", %{workspace: workspace} do
      Application.put_env(:flux, :model_pricing, %{"echo-1" => {1.0, 2.0}})
      on_exit(fn -> Application.delete_env(:flux, :model_pricing) end)

      assert {:ok, result} =
               Flux.Providers.playground_run(workspace.id, "echo", "echo-1", "race me")

      assert result.content =~ "You said: race me"
      assert result.latency_ms >= 0
      assert result.output_tokens == 12
      assert result.cost_usd > 0

      assert {:error, _reason} =
               Flux.Providers.playground_run(workspace.id, "nope", "ghost-1", "race me")
    end
  end

  describe "workspace archive" do
    test "owner archives; it leaves resolution; admin restores", %{
      account: account,
      scope: scope,
      workspace: workspace
    } do
      {:ok, archived} = Accounts.archive_workspace(scope)
      assert archived.status == "archived"

      # No longer anyone's current workspace.
      fresh_scope = Accounts.scope_for(account)
      assert fresh_scope.workspace == nil

      assert [%{id: listed_id}] = Accounts.archived_workspaces()
      assert listed_id == workspace.id

      {:ok, restored} = Accounts.restore_workspace(workspace.id)
      assert restored.status == "normal"
      assert Accounts.scope_for(account).workspace.id == workspace.id
    end
  end

  describe "monthly cost report" do
    test "fires on the 1st at 08:00 with last month's rollup", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Report Flux"})

      last_month =
        Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()

      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :succeeded,
        usage: %{"input_tokens" => 100, "output_tokens" => 50, "estimated_cost_usd" => 0.25},
        inserted_at: DateTime.new!(Date.add(last_month, 5), ~T[12:00:00])
      })

      first = Date.utc_today() |> Date.beginning_of_month()
      tick = DateTime.new!(first, ~T[08:00:00])

      :ok = Flux.Usage.send_monthly_cost_reports(tick)

      report = Enum.find(Flux.Notifications.list(scope), &(&1.kind == "cost_report"))
      assert report != nil
      assert report.title =~ "150 tokens"
      assert report.title =~ "Report Flux"
      assert report.title =~ "$0.25"

      # Idempotent within the month.
      :ok = Flux.Usage.send_monthly_cost_reports(tick)
      assert Enum.count(Flux.Notifications.list(scope), &(&1.kind == "cost_report")) == 1
    end
  end

  describe "llm cache stats" do
    test "hits and misses count" do
      Flux.LLMCache.purge()
      key = :crypto.hash(:sha256, "b20-stats-key")

      assert :miss = Flux.LLMCache.get(key)
      :ok = Flux.LLMCache.put(key, %{content: "cached"}, 5)
      assert {:ok, _response} = Flux.LLMCache.get(key)

      stats = Flux.LLMCache.stats()
      assert stats.hits >= 1
      assert stats.misses >= 1
      assert stats.entries >= 1
      assert stats.hit_rate > 0.0
    end
  end
end
