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
