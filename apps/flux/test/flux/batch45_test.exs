defmodule Flux.Batch45Test do
  use Flux.DataCase, async: false
  use Oban.Testing, repo: Flux.Repo

  import Flux.AccountsFixtures
  import Swoosh.TestAssertions

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch45 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B45 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
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

  defp add_member(workspace, email) do
    other = account_fixture(%{email: email})
    {:ok, _membership} = Accounts.scim_provision(workspace, other.email)
    Accounts.get_account!(other.id)
  end

  describe "assignee notifications" do
    test "assignment mails the assignee; self-claim stays quiet", %{
      scope: scope,
      workspace: workspace
    } do
      teammate = add_member(workspace, "teammate-b45@example.com")
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{title: "Angry customer"})

      drain_emails()
      {:ok, _assigned} = Chat.assign_handoff(scope, conversation.id, teammate.id)

      assert_email_sent(fn email ->
        [{_name, to}] = email.to
        to == teammate.email and email.subject =~ "assigned to you"
      end)

      # Self-claim: no mail to yourself.
      drain_emails()
      {:ok, _self} = Chat.assign_handoff(scope, conversation.id, scope.account.id)
      refute_email_sent()

      # Releasing notifies nobody either.
      {:ok, _released} = Chat.assign_handoff(scope, conversation.id, nil)
      refute_email_sent()
    end

    test "auto-assignment notifies the routed member", %{scope: scope, workspace: workspace} do
      teammate = add_member(workspace, "routed-b45@example.com")
      {:ok, _workspace} = Accounts.set_handoff_auto_assign(scope, true)
      # Only the teammate is available — routing is deterministic.
      {:ok, _membership} = Accounts.set_availability(scope, false)

      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_route"})

      drain_emails()
      {:ok, assigned} = Chat.request_handoff(scope, app, conversation.id)
      assert assigned.assigned_account_id == teammate.id

      assert_email_sent(fn email ->
        [{_name, to}] = email.to
        to == teammate.email and email.subject =~ "assigned to you"
      end)
    end
  end

  describe "workspace-wide conversation search" do
    test "finds titles and message bodies across apps with excerpts", %{scope: scope} do
      app_a = echo_app(scope, %{"name" => "Support"})
      app_b = echo_app(scope, %{"name" => "Sales"})

      titled = Chat.create_conversation(scope, app_a, %{title: "Flux capacitor questions"})
      bodied = Chat.create_conversation(scope, app_b, %{title: "Untitled thread"})

      Flux.Repo.insert!(%Flux.Chat.Message{
        workspace_id: titled.workspace_id,
        conversation_id: bodied.id,
        role: :user,
        content: "do you stock flux capacitors in bulk?"
      })

      results = Chat.search_conversations_global(scope, "flux capacitor")
      assert length(results) == 2

      by_app = Map.new(results, &{&1.app_name, &1})
      assert by_app["Support"].conversation.id == titled.id
      assert by_app["Sales"].excerpt =~ "stock flux capacitors"

      assert Chat.search_conversations_global(scope, "jigawatt") == []
    end
  end

  describe "per-app webhook filtering" do
    test "app-bound endpoints receive only their app's events", %{scope: scope} do
      app = echo_app(scope, %{"name" => "Bound App"})
      other = echo_app(scope, %{"name" => "Other App"})

      {:ok, _bound} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://hooks.example.com/bound",
          "events" => ["conversation.started", "run.failed"],
          "app_id" => app.id
        })

      {:ok, _open} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://hooks.example.com/open",
          "events" => ["conversation.started", "run.failed"]
        })

      # This app's event: both receive.
      Chat.create_conversation(scope, app)
      # The other app's event: only the unbound endpoint.
      Chat.create_conversation(scope, other)

      deliveries =
        all_enqueued(worker: Flux.Workflows.AlertWorker)
        |> Enum.map(&{&1.args["url"], &1.args["payload"]["app_id"]})

      bound = Enum.filter(deliveries, fn {url, _} -> url =~ "bound" end)
      open = Enum.filter(deliveries, fn {url, _} -> url =~ "open" end)

      assert length(bound) == 1
      assert [{_url, app_id}] = bound
      assert app_id == app.id
      assert length(open) == 2

      # Events without an app id (runs, notifications) skip bound
      # endpoints entirely.
      :ok = Flux.Webhooks.dispatch(app.workspace_id, "run.failed", %{"run_id" => "r1"})

      run_deliveries =
        all_enqueued(worker: Flux.Workflows.AlertWorker)
        |> Enum.filter(&(&1.args["payload"]["event"] == "run.failed"))
        |> Enum.map(& &1.args["url"])

      assert run_deliveries == ["https://hooks.example.com/open"]
    end
  end

  describe "batch cost preview" do
    test "run_averages reports the mean and honest zero-sample", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Priced Flux"})

      assert Flux.Workflows.run_averages(scope, workflow.id) == %{
               sample: 0,
               avg_tokens: 0,
               avg_cost: 0.0
             }

      for tokens <- [100, 300] do
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :succeeded,
          usage: %{
            "input_tokens" => tokens,
            "output_tokens" => tokens,
            "estimated_cost_usd" => 0.01
          }
        })
      end

      # A failed run never skews the estimate.
      Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :failed,
        usage: %{"input_tokens" => 999_999, "output_tokens" => 0}
      })

      averages = Flux.Workflows.run_averages(scope, workflow.id)
      assert averages.sample == 2
      assert averages.avg_tokens == 400
      assert_in_delta averages.avg_cost, 0.01, 0.0001
    end
  end

  describe "hardening" do
    test "model-allowlist can't be dodged by updating only the model", %{scope: scope} do
      app = echo_app(scope)
      {:ok, _workspace} = Accounts.set_model_allowlist(scope, ["echo|echo-1"])

      # Changing just the model under the existing provider still checks.
      assert {:error, :model_not_allowed} =
               Chat.update_app(scope, app, %{"model" => "echo-embed"})

      # Untouched model fields sail through (renames must not break).
      assert {:ok, _app} = Chat.update_app(scope, app, %{"name" => "Renamed"})
    end

    test "resume refuses while the workspace is suspended", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Paused Flux"})

      run =
        Flux.Repo.insert!(%Flux.Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :paused,
          snapshot: %{"node_id" => "ask", "prompt" => "Continue?"}
        })

      {:ok, _workspace} = Accounts.suspend_workspace(workspace.id)

      assert {:error, :workspace_suspended} =
               Flux.Workflows.resume_run(scope, run.id, "yes")
    end

    test "draft_reply requires the monitor permission", %{scope: scope} do
      app = echo_app(scope)
      conversation = Chat.create_conversation(scope, app)

      # A site scope (no membership) has no console permissions.
      assert {:error, :unauthorized} =
               Chat.draft_reply(Chat.site_scope(app), conversation.id)
    end

    test "the throttle sweep clears stale minute counters" do
      minute = div(System.system_time(:second), 60)
      stale_key = {"sweep-test-ws", "sweep-test-plugin", minute - 30}
      fresh_key = {"sweep-test-ws", "sweep-test-plugin", minute}

      :ets.insert(:flux_provider_throttle, {stale_key, 5})
      :ets.insert(:flux_provider_throttle, {fresh_key, 5})

      send(Process.whereis(Flux.ProviderThrottle), :sweep)
      # The sweep is a cast-style message; give the GenServer a beat.
      :sys.get_state(Flux.ProviderThrottle)

      assert :ets.lookup(:flux_provider_throttle, stale_key) == []
      assert [{^fresh_key, 5}] = :ets.lookup(:flux_provider_throttle, fresh_key)
    end
  end
end
