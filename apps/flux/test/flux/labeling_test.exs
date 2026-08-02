defmodule Flux.LabelingTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Labeling

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Label WS"})
    scope = Accounts.scope_for(account)
    %{scope: scope, account: account, workspace: workspace}
  end

  test "project lifecycle and schema validation", %{scope: scope} do
    refute Labeling.configured?(scope)

    assert {:error, changeset} =
             Labeling.create_project(scope, %{"name" => "Bad", "label_type" => "choice"})

    assert %{options: [message]} = errors_on(changeset)
    assert message =~ "at least two options"

    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Intent",
        "label_type" => "choice",
        "options" => [" complaint", "question", "praise", ""]
      })

    assert project.options == ["complaint", "question", "praise"]
    assert Labeling.configured?(scope)

    {:ok, _} = Labeling.delete_project(scope, project.id)
    assert Labeling.list_projects(scope) == []
  end

  test "the queue: add, label, skip, relabel, counts", %{scope: scope, account: account} do
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Intent",
        "label_type" => "choice",
        "options" => ["complaint", "question"]
      })

    {:ok, _} = Labeling.add_task(scope, project, %{"text" => "refund me"}, "manual")
    {:ok, _} = Labeling.add_task(scope, project, %{"text" => "what are your hours?"})
    {:ok, _} = Labeling.add_task(scope, project, %{"text" => "gibberish"})

    task = Labeling.next_task(scope, project.id)
    assert task.data["text"] == "refund me"

    # Wrong-schema labels are refused.
    assert {:error, :invalid_label} = Labeling.label_task(scope, task.id, %{"choice" => "nope"})
    assert {:error, :invalid_label} = Labeling.label_task(scope, task.id, %{"text" => "x"})

    {:ok, labeled} = Labeling.label_task(scope, task.id, %{"choice" => "complaint"})
    assert labeled.status == :labeled
    assert labeled.labeled_by_id == account.id

    second = Labeling.next_task(scope, project.id)
    {:ok, _} = Labeling.label_task(scope, second.id, %{"choice" => "question"})

    third = Labeling.next_task(scope, project.id)
    {:ok, _} = Labeling.skip_task(scope, third.id)

    assert Labeling.next_task(scope, project.id) == nil
    assert Labeling.counts(scope, project.id) == %{unlabeled: 0, labeled: 2, skipped: 1}

    # Relabeling overwrites in place.
    {:ok, relabeled} = Labeling.label_task(scope, labeled.id, %{"choice" => "question"})
    assert relabeled.label == %{"choice" => "question"}
    assert Labeling.counts(scope, project.id).labeled == 2

    assert [%{label: %{"choice" => "question"}} | _rest] =
             Labeling.list_labeled(scope, project.id)
  end

  test "multi and text label schemas", %{scope: scope} do
    {:ok, multi} =
      Labeling.create_project(scope, %{
        "name" => "Tags",
        "label_type" => "multi",
        "options" => ["urgent", "billing"]
      })

    {:ok, _} = Labeling.add_task(scope, multi, %{"text" => "urgent billing issue"})
    task = Labeling.next_task(scope, multi.id)

    assert {:error, :invalid_label} = Labeling.label_task(scope, task.id, %{"choices" => []})

    assert {:ok, _} =
             Labeling.label_task(scope, task.id, %{"choices" => ["urgent", "billing"]})

    {:ok, text_project} =
      Labeling.create_project(scope, %{"name" => "Corrections", "label_type" => "text"})

    {:ok, _} = Labeling.add_task(scope, text_project, %{"answer" => "teh answer"})
    task = Labeling.next_task(scope, text_project.id)

    assert {:error, :invalid_label} = Labeling.label_task(scope, task.id, %{"text" => "  "})
    assert {:ok, _} = Labeling.label_task(scope, task.id, %{"text" => "the answer"})
  end

  test "CSV rows import and labeled tasks export as JSONL", %{scope: scope} do
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Intent",
        "label_type" => "choice",
        "options" => ["complaint", "question"]
      })

    {:ok, tasks} =
      Labeling.add_tasks_from_rows(scope, project, [
        %{"text" => "refund me", "channel" => "email"},
        %{"text" => "hours?", "channel" => "chat"}
      ])

    assert length(tasks) == 2
    assert Enum.all?(tasks, &(&1.source == "csv"))

    task = Labeling.next_task(scope, project.id)
    {:ok, _} = Labeling.label_task(scope, task.id, %{"choice" => "complaint"})

    {:ok, jsonl} = Labeling.export_jsonl(scope, project.id)
    [line] = String.split(jsonl, "\n")
    decoded = Jason.decode!(line)
    assert decoded["data"]["text"] == "refund me"
    assert decoded["label"] == %{"choice" => "complaint"}
  end

  test "the monitor's queue_item path and RBAC", %{scope: scope, workspace: workspace} do
    {:ok, project} =
      Labeling.create_project(scope, %{"name" => "Review", "label_type" => "text"})

    {:ok, task} =
      Labeling.queue_item(scope, project.id, %{"question" => "q", "answer" => "a"})

    assert task.source == "feedback"
    assert {:error, :not_found} = Labeling.queue_item(scope, Ecto.UUID.generate(), %{})

    member = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: member.id,
        role: :normal
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace.id)
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} =
             Labeling.create_project(member_scope, %{"name" => "X", "label_type" => "text"})

    assert {:error, :unauthorized} =
             Labeling.label_task(member_scope, task.id, %{"text" => "nope"})
  end
end
