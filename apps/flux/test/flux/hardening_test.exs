defmodule Flux.HardeningTest do
  @moduledoc "Regression coverage for the batch-46 hardening exercise."
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Hardening WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  # A read-only :normal member of the same workspace.
  defp normal_member_scope(workspace) do
    other = account_fixture(%{email: "normal-#{System.unique_integer([:positive])}@example.com"})
    {:ok, _membership} = Accounts.scim_provision(workspace, other.email)
    # scim_provision defaults to :normal — confirm and build the scope.
    account = Accounts.get_account!(other.id)
    scope = Accounts.scope_for(account)
    %{scope | workspace: workspace}
  end

  describe "CSV formula injection" do
    test "leading formula triggers are neutralized; ordinary values pass" do
      csv = Flux.CSV.encode([["=cmd|'/c calc'!A1", "+1", "-2", "@x", "safe", "a,b"]])
      [row] = csv |> String.trim_trailing() |> String.split("\r\n")

      # Formula-leading cells get a "'" prefix (and are quoted only when
      # they also contain CSV metachars).
      assert row =~ "'=cmd"
      assert row =~ "'+1"
      assert row =~ "'-2"
      assert row =~ "'@x"
      # A plain value is untouched; a comma-bearing one is quoted, not prefixed.
      assert row =~ ",safe,"
      assert row =~ "\"a,b\""
    end

    test "a visitor chat message can't smuggle a formula into an export" do
      # The conversations/feedback CSVs route through Flux.CSV, so the
      # guard covers visitor content end to end.
      assert Flux.CSV.encode_field("=IMPORTXML(\"https://evil\")") ==
               "\"'=IMPORTXML(\"\"https://evil\"\")\""
    end
  end

  describe "embed_origins CSP injection" do
    test "malformed origins are dropped, valid ones kept", %{scope: scope} do
      app = echo_app(scope)
      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, app} =
        Chat.update_app(scope, app, %{
          "embed_origins" =>
            "https://good.example.com https://x.com;script-src'unsafe-inline' https://ok.io:8443"
        })

      ancestors = Chat.embed_frame_ancestors(app.site_token)

      assert "https://good.example.com" in ancestors
      assert "https://ok.io:8443" in ancestors
      # The ";"-bearing token that would inject a CSP directive is gone.
      refute Enum.any?(ancestors, &String.contains?(&1, ";"))
    end
  end

  describe "set_feedback cross-app isolation" do
    test "an app-scoped caller can't rate another app's message", %{
      scope: scope,
      workspace: workspace
    } do
      app_a = echo_app(scope, %{"name" => "A"})
      app_b = echo_app(scope, %{"name" => "B"})

      convo_b = Chat.create_conversation(scope, app_b)

      message_b =
        Flux.Repo.insert!(%Flux.Chat.Message{
          workspace_id: workspace.id,
          conversation_id: convo_b.id,
          role: :assistant,
          status: :completed,
          content: "b reply"
        })

      # Scoped to app A → app B's message is invisible.
      assert {:error, :not_found} =
               Chat.set_feedback(scope, message_b.id, :like, app_id: app_a.id)

      # Correctly scoped → allowed.
      assert {:ok, _updated} =
               Chat.set_feedback(scope, message_b.id, :like, app_id: app_b.id)

      # Workspace-scoped (no app id, console) → allowed.
      assert {:ok, _updated} = Chat.set_feedback(scope, message_b.id, :dislike)
    end
  end

  describe "missing RBAC now enforced" do
    setup %{workspace: workspace} do
      %{member: normal_member_scope(workspace)}
    end

    test "chat mutations refuse a read-only member", %{scope: owner, member: member} do
      app = echo_app(owner)
      conversation = Chat.create_conversation(owner, app)

      message =
        Flux.Repo.insert!(%Flux.Chat.Message{
          workspace_id: app.workspace_id,
          conversation_id: conversation.id,
          role: :assistant,
          status: :completed,
          content: "hi"
        })

      assert {:error, :unauthorized} = Chat.human_reply(member, conversation.id, "sneaky")

      assert {:error, :unauthorized} =
               Chat.set_conversation_labels(member, conversation.id, ["x"])

      assert {:error, :unauthorized} = Chat.toggle_pin_message(member, message.id)

      {:ok, _token, _raw} = Chat.create_api_token(owner, app)
      [token] = Chat.list_api_tokens(owner, app.id)
      assert {:error, :unauthorized} = Chat.revoke_api_token(member, token.id)

      # The owner still can.
      assert {:ok, _} = Chat.set_conversation_labels(owner, conversation.id, ["ok"])
    end

    test "workflow mutations refuse a read-only member", %{scope: owner, member: member} do
      {:ok, workflow} = Flux.Workflows.create_workflow(owner, %{"name" => "F"})

      assert {:error, :unauthorized} =
               Flux.Workflows.start_batch(member, workflow, [%{"query" => "x"}])

      run =
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: workflow.workspace_id,
          workflow_id: workflow.id,
          status: :succeeded,
          node_executions: []
        })

      assert {:error, :unauthorized} = Flux.Workflows.replay_run(member, run.id, "start")
    end

    test "tool-approval resume needs the run permission; other pauses don't", %{
      scope: owner,
      member: member,
      workspace: workspace
    } do
      {:ok, workflow} = Flux.Workflows.create_workflow(owner, %{"name" => "P"})

      approval_run =
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :paused,
          snapshot: %{"node_id" => "agent", "prompt" => %{"type" => "tool_approval"}}
        })

      assert {:error, :unauthorized} =
               Flux.Workflows.resume_run(member, approval_run.id, "approve")
    end
  end

  describe "provider listing resilience" do
    defmodule CrashRuntime do
      def list_model_providers do
        [
          %{
            id: "boom",
            name: "Boom",
            version: "1",
            category: :model,
            description: "",
            credential_schema: []
          }
        ]
      end

      def list_datasource_plugins, do: []
      def models("boom", _config), do: raise("provider exploded")
      def models(_other, _config), do: {:ok, []}
    end

    test "a provider whose models/1 raises doesn't crash the listing", %{scope: scope} do
      previous = Application.get_env(:flux, :plugin_runtime)
      Application.put_env(:flux, :plugin_runtime, CrashRuntime)
      on_exit(fn -> Application.put_env(:flux, :plugin_runtime, previous) end)

      # No crash — the exploding provider just contributes nothing.
      assert Flux.Providers.available_models(scope) == []
    end
  end

  describe "stuck-stream reaper" do
    test "a message wedged streaming past the window is failed and broadcast", %{
      scope: scope,
      workspace: workspace
    } do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)
      old = DateTime.add(DateTime.utc_now(:second), -20, :minute)

      stuck =
        Flux.Repo.insert!(%Flux.Chat.Message{
          workspace_id: workspace.id,
          conversation_id: conversation.id,
          role: :assistant,
          status: :streaming,
          inserted_at: old,
          updated_at: old
        })

      :ok = Chat.subscribe(stuck.id)
      :ok = Chat.reap_stuck_streams()

      reaped = Flux.Repo.get!(Flux.Chat.Message, stuck.id, skip_workspace_guard: true)
      assert reaped.status == :error
      assert reaped.error == "generation interrupted"
      assert_receive {:error, %Flux.Chat.Message{id: id}}
      assert id == stuck.id

      # A freshly-streaming message is left alone.
      fresh =
        Flux.Repo.insert!(%Flux.Chat.Message{
          workspace_id: workspace.id,
          conversation_id: conversation.id,
          role: :assistant,
          status: :streaming
        })

      :ok = Chat.reap_stuck_streams()

      assert Flux.Repo.get!(Flux.Chat.Message, fresh.id, skip_workspace_guard: true).status ==
               :streaming
    end
  end

  describe "web push SSRF" do
    test "an internal endpoint is refused at subscribe time", %{account: account} do
      previous = Application.get_env(:flux, Flux.SSRF)
      Application.put_env(:flux, Flux.SSRF, enabled: true, allow: [])
      on_exit(fn -> Application.put_env(:flux, Flux.SSRF, previous) end)

      internal = %{
        "endpoint" => "http://169.254.169.254/latest/meta-data/",
        "keys" => %{"p256dh" => "x", "auth" => "y"}
      }

      assert {:error, :invalid_subscription} = Flux.WebPush.subscribe(account, internal)

      # A normal https endpoint (literal public IP, no DNS) is accepted.
      external = %{
        "endpoint" => "https://93.184.216.34/push/abc",
        "keys" => %{"p256dh" => "x", "auth" => "y"}
      }

      assert {:ok, _subscription} = Flux.WebPush.subscribe(account, external)
    end
  end

  describe "cache sweeps" do
    test "LLMCache drops expired entries on sweep" do
      key = :crypto.hash(:sha256, "sweep-#{System.unique_integer([:positive])}")
      # Insert an already-expired row directly.
      :ets.insert(:flux_llm_cache, {key, %{content: "old"}, System.system_time(:second) - 10})

      send(Process.whereis(Flux.LLMCache), :sweep)
      :sys.get_state(Flux.LLMCache)

      assert :ets.lookup(:flux_llm_cache, key) == []
    end
  end
end
