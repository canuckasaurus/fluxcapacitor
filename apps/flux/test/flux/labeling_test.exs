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

  test "a labeling node pauses the run and the label resumes it", %{scope: scope} do
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Review",
        "label_type" => "text"
      })

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "config" => %{
            "variables" => [%{"name" => "question", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "draft",
          "type" => "llm",
          "title" => "Draft",
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "prompt" => "{{start.question}}"
          }
        },
        %{
          "id" => "review",
          "type" => "labeling",
          "title" => "Human review",
          "config" => %{
            "project_id" => project.id,
            "data" => [
              %{"name" => "question", "value" => "{{start.question}}"},
              %{"name" => "answer", "value" => "{{draft.text}}"}
            ]
          }
        },
        %{
          "id" => "answer",
          "type" => "answer",
          "title" => "Answer",
          "config" => %{"answer" => "Reviewed: {{review.text}}"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "draft"},
        %{"id" => "e2", "source" => "draft", "source_handle" => "default", "target" => "review"},
        %{"id" => "e3", "source" => "review", "source_handle" => "default", "target" => "answer"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Reviewed Flux"})
    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, run} = Flux.Workflows.start_run(scope, workflow, %{"question" => "may I?"})

    assert_receive {:run_finished, %{status: :paused} = paused}, 5_000
    assert paused.snapshot["prompt"]["type"] == "labeling"

    # The node queued a task carrying its run.
    task = Labeling.next_task(scope, project.id)
    assert task.run_id == run.id
    assert task.node_id == "review"
    assert task.data["question"] == "may I?"
    assert task.data["answer"] =~ "You said: may I?"

    # Labeling it resumes the run with the label as the node's outputs.
    {:ok, _} = Labeling.label_task(scope, task.id, %{"text" => "Yes, approved."})

    assert_receive {:run_finished, %{status: :succeeded} = finished}, 5_000
    assert finished.outputs["answer"] == "Reviewed: Yes, approved."
  end

  test "claims keep two labelers off the same task", %{scope: scope, workspace: workspace} do
    {:ok, project} =
      Labeling.create_project(scope, %{"name" => "Shared", "label_type" => "text"})

    {:ok, _} = Labeling.add_task(scope, project, %{"text" => "one"})
    {:ok, _} = Labeling.add_task(scope, project, %{"text" => "two"})

    # A second editor in the same workspace.
    other = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: other.id,
        role: :editor
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(other, workspace.id)
    other_scope = Accounts.scope_for(other)

    mine = Labeling.next_task(scope, project.id)
    theirs = Labeling.next_task(other_scope, project.id)

    assert mine.id != theirs.id
    # Re-fetching keeps my own claim stable.
    assert Labeling.next_task(scope, project.id).id == mine.id

    {:ok, _} = Labeling.label_task(scope, mine.id, %{"text" => "done"})
    {:ok, _} = Labeling.label_task(other_scope, theirs.id, %{"text" => "also done"})

    stats = Labeling.labeler_stats(scope, project.id)
    assert length(stats) == 2
    assert Enum.all?(stats, fn {_email, count} -> count == 1 end)
  end

  test "consensus projects collect votes until quorum, then agree", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Consensus",
        "label_type" => "choice",
        "options" => ["complaint", "question"],
        "required_labels" => 3
      })

    {:ok, task} = Labeling.add_task(scope, project, %{"text" => "refund me"})

    others =
      for _n <- 1..2 do
        other = account_fixture()

        {:ok, _} =
          %Flux.Accounts.Membership{}
          |> Flux.Accounts.Membership.changeset(%{
            workspace_id: workspace.id,
            account_id: other.id,
            role: :editor
          })
          |> Repo.insert()

        {:ok, _} = Accounts.switch_workspace(other, workspace.id)
        Accounts.scope_for(other)
      end

    [second_scope, third_scope] = others

    # First vote: task stays unlabeled, and the voter never sees it again.
    {:ok, after_vote} = Labeling.label_task(scope, task.id, %{"choice" => "complaint"})
    assert after_vote.status == :unlabeled
    assert Labeling.next_task(scope, project.id) == nil

    # Other labelers still get it.
    assert Labeling.next_task(second_scope, project.id).id == task.id
    {:ok, still} = Labeling.label_task(second_scope, task.id, %{"choice" => "question"})
    assert still.status == :unlabeled

    # Third vote reaches quorum: 2-1 for complaint becomes the label.
    {:ok, labeled} = Labeling.label_task(third_scope, task.id, %{"choice" => "complaint"})
    assert labeled.status == :labeled
    assert labeled.label == %{"choice" => "complaint"}

    stats = Labeling.agreement_stats(scope, project.id)
    assert stats.tasks == 1
    assert stats.unanimous == 0
    assert_in_delta stats.avg_agreement, 2 / 3, 1.0e-9
  end

  test "gold tasks score labeler accuracy (single-label path)", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Gold",
        "label_type" => "choice",
        "options" => ["complaint", "question"]
      })

    {:ok, task} = Labeling.add_task(scope, project, %{"text" => "refund me"})
    {:ok, _} = Labeling.label_task(scope, task.id, %{"choice" => "complaint"})

    # Unlabeled tasks can't be promoted; labeled ones re-enter the queue.
    {:ok, other} = Labeling.add_task(scope, project, %{"text" => "hours?"})
    assert {:error, :not_labeled} = Labeling.promote_to_gold(scope, other.id)

    {:ok, gold} = Labeling.promote_to_gold(scope, task.id)
    assert gold.status == :unlabeled
    assert gold.gold_label == %{"choice" => "complaint"}
    assert gold.label == nil

    # A second labeler answers wrong; the owner answers right.
    other_account = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: other_account.id,
        role: :editor
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(other_account, workspace.id)
    other_scope = Accounts.scope_for(other_account)

    {:ok, _} = Labeling.label_task(other_scope, gold.id, %{"choice" => "question"})
    {:ok, _} = Labeling.label_task(scope, other.id, %{"choice" => "question"})

    # Only the gold task scores; the wrong answer shows as 0/1.
    accuracy = Labeling.labeler_accuracy(scope, project)
    assert [{email, 0, 1}] = accuracy
    assert email == other_account.email
  end

  test "gold tasks score every vote in consensus projects", %{
    scope: scope,
    workspace: workspace
  } do
    {:ok, project} =
      Labeling.create_project(scope, %{
        "name" => "Gold votes",
        "label_type" => "choice",
        "options" => ["a", "b"],
        "required_labels" => 2
      })

    {:ok, task} = Labeling.add_task(scope, project, %{"text" => "x"})

    other = account_fixture()

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace.id,
        account_id: other.id,
        role: :editor
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(other, workspace.id)
    other_scope = Accounts.scope_for(other)

    # First consensus round labels it a; promote that to gold.
    {:ok, _} = Labeling.label_task(scope, task.id, %{"choice" => "a"})
    {:ok, labeled} = Labeling.label_task(other_scope, task.id, %{"choice" => "a"})
    assert labeled.status == :labeled

    {:ok, _gold} = Labeling.promote_to_gold(scope, task.id)

    # Fresh round: one right vote, one wrong vote.
    {:ok, _} = Labeling.label_task(scope, task.id, %{"choice" => "a"})
    {:ok, _} = Labeling.label_task(other_scope, task.id, %{"choice" => "b"})

    accuracy = Labeling.labeler_accuracy(scope, project)
    assert length(accuracy) == 2
    assert {_right_email, 1, 1} = List.first(accuracy)
    assert {wrong_email, 0, 1} = List.last(accuracy)
    assert wrong_email == other.email
  end

  test "single-labeler projects report no agreement stats", %{scope: scope} do
    {:ok, project} =
      Labeling.create_project(scope, %{"name" => "Solo", "label_type" => "text"})

    {:ok, task} = Labeling.add_task(scope, project, %{"text" => "hi"})
    {:ok, _} = Labeling.label_task(scope, task.id, %{"text" => "hello"})

    assert Labeling.agreement_stats(scope, project.id) == nil
  end

  test "batch results fan into a project", %{scope: scope} do
    {:ok, project} =
      Labeling.create_project(scope, %{"name" => "Batchy", "label_type" => "text"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "config" => %{
            "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "llm_1",
          "type" => "llm",
          "title" => "LLM",
          "config" => %{
            "provider_plugin_id" => "echo",
            "model" => "echo-1",
            "prompt" => "{{start.query}}"
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

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Fan"})
    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)

    {:ok, batch} =
      Flux.Workflows.start_batch(scope, workflow, [%{"query" => "a"}, %{"query" => "b"}])

    :ok = Flux.Workflows.perform_batch(batch.id)

    {:ok, tasks} = Labeling.add_tasks_from_batch(scope, project, batch.id)
    assert length(tasks) == 2
    assert Enum.all?(tasks, &(&1.source == "batch"))
    assert hd(tasks).data["output"] =~ "You said:"
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
