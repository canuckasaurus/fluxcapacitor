defmodule Flux.NotificationEmailTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures
  import Swoosh.TestAssertions

  alias Flux.Accounts

  test "opted-in members get notification kinds by email, others don't" do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Email WS"})

    # Unknown kinds are dropped at save time.
    {:ok, account} =
      Accounts.set_notification_email_kinds(account, ["run_failed", "digest", "bogus"])

    assert account.notification_email_kinds == ["run_failed", "digest"]

    # Drain the fixture's confirmation email before asserting ours.
    drain_emails()

    :ok = Flux.Notifications.notify(workspace.id, "run_failed", "The flux blew a fuse")

    assert_email_sent(
      subject: "[FluxCapacitor] Run failed",
      to: account.email,
      text_body: ~r/The flux blew a fuse/
    )

    # A kind the account didn't opt into stays console-only.
    :ok = Flux.Notifications.notify(workspace.id, "guardrail", "Pattern matched")
    refute_email_sent(subject: "[FluxCapacitor] Guardrail")
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end
end

defmodule Flux.NotificationsRegistryTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Notifications
  alias Flux.Registry
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Notify WS"})
    scope = Accounts.scope_for(account)
    %{scope: scope, workspace: workspace}
  end

  test "notifications record, count unread, and mark read", %{
    scope: scope,
    workspace: workspace
  } do
    :ok = Notifications.notify(workspace.id, "run_failed", "Run failed: Test", "/console/runs")
    :ok = Notifications.notify(workspace.id, "labeling_completed", "Done labeling")

    assert Notifications.unread_count(scope) == 2
    assert [%{kind: "labeling_completed"}, %{kind: "run_failed"}] = Notifications.list(scope)

    # Kind filters narrow the feed; single mark-read leaves the rest unread.
    assert [%{kind: "run_failed"}] = Notifications.list(scope, 30, "run_failed")
    [first | _rest] = Notifications.list(scope)
    :ok = Notifications.mark_read(scope, first.id)
    assert Notifications.unread_count(scope) == 1

    :ok = Notifications.mark_all_read(scope)
    assert Notifications.unread_count(scope) == 0

    assert_raise FunctionClauseError, fn ->
      Notifications.notify(workspace.id, "made_up_kind", "nope")
    end
  end

  test "failed runs notify the workspace", %{scope: scope} do
    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "config" => %{"variables" => []}
        },
        %{
          "id" => "llm_1",
          "type" => "llm",
          "title" => "LLM",
          "config" => %{
            "provider_plugin_id" => "not_installed",
            "model" => "ghost-1",
            "prompt" => "x"
          }
        },
        %{
          "id" => "answer_1",
          "type" => "answer",
          "title" => "Answer",
          "config" => %{"answer" => "{{llm_1.text}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "llm_1"},
        %{"id" => "e2", "source" => "llm_1", "source_handle" => "default", "target" => "answer_1"}
      ]
    }

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Doomed"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Workflows.start_run(scope, workflow, %{})
    assert_receive {:run_finished, %{status: :failed}}, 5_000

    assert [notification | _rest] = Notifications.list(scope)
    assert notification.kind == "run_failed"
    assert notification.title =~ "Doomed"
  end

  test "the registry names and versions stored files", %{scope: scope, workspace: workspace} do
    {:ok, stored} = Workflows.store_workspace_file(workspace.id, "model.joblib", <<1, 2, 3>>)

    {:ok, v1} = Registry.register(scope, "ticket-intent", stored["file_id"])
    assert v1.version == 1

    {:ok, v2} =
      Registry.register(scope, "ticket-intent", stored["file_id"], metrics: %{"acc" => 0.9})

    assert v2.version == 2
    assert v2.metrics == %{"acc" => 0.9}

    assert [latest] = Registry.latest(scope)
    assert latest.version == 2
    assert latest.file.name == "model.joblib"

    assert {:error, :blank_name} = Registry.register(scope, "  ", stored["file_id"])
    assert {:error, :file_not_found} = Registry.register(scope, "x", Ecto.UUID.generate())

    {:ok, _} = Registry.delete(scope, v2.id)
    assert [%{version: 1}] = Registry.latest(scope)
  end

  test "registry: attachments resolve latest version at run time", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, old} = Workflows.store_workspace_file(workspace.id, "model-v1.joblib", "old model")
    {:ok, new} = Workflows.store_workspace_file(workspace.id, "model-v2.joblib", "new model")

    {:ok, _v1} = Registry.register(scope, "intent", old["file_id"])
    {:ok, _v2} = Registry.register(scope, "intent", new["file_id"])

    spec = %{
      language: "python3",
      code: "def main(): return {}",
      dependencies: [],
      inputs: %{},
      attachments: [%{"file_id" => "registry:intent", "name" => "model.joblib"}]
    }

    assert {:ok, %{result: %{"files" => ["model.joblib"]}}} =
             Flux.CodeRunner.run(spec, workspace.id)

    # Unknown registry names fail honestly instead of resolving.
    bad = %{spec | attachments: [%{"file_id" => "registry:ghost"}]}
    assert {:error, message} = Flux.CodeRunner.run(bad, workspace.id)
    assert message =~ "not found"
  end

  test "labeling trash restores; the cleanup sweep bounds the logs", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, project} =
      Flux.Labeling.create_project(scope, %{"name" => "Trashy", "label_type" => "text"})

    {:ok, _} = Flux.Labeling.delete_project(scope, project.id)

    assert Flux.Labeling.list_projects(scope) == []
    assert [%{name: "Trashy"}] = Flux.Labeling.list_trashed_projects(scope)

    {:ok, restored} = Flux.Labeling.restore_project(scope, project.id)
    assert restored.deleted_at == nil
    assert [_project] = Flux.Labeling.list_projects(scope)

    # Old notifications and deliveries sweep out on the nightly job.
    old = DateTime.add(DateTime.utc_now(:second), -120, :day)

    Repo.insert!(%Notifications.Notification{
      workspace_id: workspace.id,
      kind: "run_failed",
      title: "ancient",
      inserted_at: old,
      updated_at: old
    })

    :ok = Notifications.notify(workspace.id, "run_failed", "fresh")

    assert :ok = Flux.Workflows.CleanupWorker.perform(%Oban.Job{args: %{}})

    titles = Enum.map(Notifications.list(scope, 50), & &1.title)
    assert "fresh" in titles
    refute "ancient" in titles
  end

  test "the weekly digest fires on Monday mornings, once", %{scope: scope, workspace: workspace} do
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Digest Flux"})

    Repo.insert!(%Flux.Workflows.WorkflowRun{
      workspace_id: workspace.id,
      workflow_id: workflow.id,
      status: :succeeded,
      usage: %{"input_tokens" => 5, "output_tokens" => 10}
    })

    monday_8am = DateTime.new!(~D[2026-08-03], ~T[08:00:00])
    :ok = Flux.Usage.send_weekly_digests(monday_8am)

    assert [digest | _rest] = Enum.filter(Notifications.list(scope), &(&1.kind == "digest"))
    assert digest.title =~ "Weekly digest: 1 runs"
    assert digest.title =~ "15 tokens"

    # Same Monday: the marker suppresses a repeat.
    :ok = Flux.Usage.send_weekly_digests(monday_8am)
    assert Enum.count(Notifications.list(scope, 50), &(&1.kind == "digest")) == 1

    # Not Monday 08:00 → nothing.
    :ok = Flux.Usage.send_weekly_digests(DateTime.new!(~D[2026-08-04], ~T[08:00:00]))
    assert Enum.count(Notifications.list(scope, 50), &(&1.kind == "digest")) == 1
  end

  test "the onboarding checklist advances as the workspace fills in", %{scope: scope} do
    empty = Flux.Usage.onboarding(scope)
    assert Enum.all?(empty, &(&1.done == false))

    :ok = Flux.Tools.install_plugin(scope, "openai")
    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "First Flux"})
    {:ok, _version} = Workflows.publish(scope, workflow)

    progressed = Map.new(Flux.Usage.onboarding(scope), &{&1.key, &1.done})
    assert progressed[:provider]
    assert progressed[:flux]
    assert progressed[:publish]
    refute progressed[:knowledge]
    refute progressed[:invite]

    # Echo alone doesn't count as "connected a provider".
    assert Enum.all?(
             Flux.Providers.list_provider_plugins(),
             &(to_string(&1.id) != "" and &1.category == :model)
           )
  end

  test "scheduled exports write the archive and notify", %{scope: scope} do
    assert {:error, :invalid_cron} = Accounts.set_export_schedule(scope, "nope")
    {:ok, _workspace} = Accounts.set_export_schedule(scope, "* * * * *")
    assert Accounts.export_schedule(scope) == "* * * * *"

    now = DateTime.utc_now(:second)
    assert [stored] = Flux.Export.run_scheduled(now)
    assert stored["name"] =~ "workspace-export-"

    # Same minute: suppressed.
    assert Flux.Export.run_scheduled(now) == []

    files = Workflows.list_workspace_files(scope)
    assert Enum.any?(files, &(&1.name == stored["name"]))

    assert Enum.any?(Notifications.list(scope), &(&1.kind == "export_ready"))

    {:ok, _} = Accounts.set_export_schedule(scope, "")
    assert Accounts.export_schedule(scope) == nil
  end
end
