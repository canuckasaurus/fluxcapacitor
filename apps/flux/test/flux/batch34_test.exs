defmodule Flux.Batch34Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch34 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace}
  end

  describe "expiring-key warnings" do
    test "keys near expiry warn exactly once", %{scope: scope, workspace: workspace} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Key App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, soon, _raw} = Chat.create_api_token(scope, app, expires_in_days: 3)
      {:ok, _far, _raw} = Chat.create_api_token(scope, app, expires_in_days: 90)
      {:ok, _forever, _raw} = Chat.create_api_token(scope, app)

      assert :ok = Chat.warn_expiring_keys()

      titles = Enum.map(Flux.Notifications.list(scope), & &1.title)
      matching = Enum.filter(titles, &(&1 =~ "expires in"))
      assert length(matching) == 1
      assert hd(matching) =~ soon.prefix

      # The second tick stays silent — warned_at gates the repeat.
      assert :ok = Chat.warn_expiring_keys()
      titles_after = Enum.map(Flux.Notifications.list(scope), & &1.title)
      assert Enum.count(titles_after, &(&1 =~ "expires in")) == 1

      reloaded = Flux.Repo.get!(Flux.Chat.ApiToken, soon.id, skip_workspace_guard: true)
      assert reloaded.expiry_warned_at != nil
      _ = workspace
    end
  end

  describe "feedback comments" do
    test "comments ride the rating and clear with it", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "FB App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "rate me")
      wait_for_completion(assistant.id)

      {:ok, rated} = Chat.set_feedback(scope, assistant.id, :dislike)
      assert rated.feedback_comment == nil

      {:ok, commented} =
        Chat.set_feedback(scope, assistant.id, :dislike, comment: "  wrong currency  ")

      assert commented.feedback_comment == "wrong currency"

      # Re-rating without a comment keeps the existing text.
      {:ok, kept} = Chat.set_feedback(scope, assistant.id, :like)
      assert kept.feedback_comment == "wrong currency"

      # Clearing the rating clears the comment.
      {:ok, cleared} = Chat.set_feedback(scope, assistant.id, nil)
      assert cleared.feedback == nil
      assert cleared.feedback_comment == nil
    end
  end

  describe "annotation editing" do
    test "edit, toggle, and validation", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Ann App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, annotation} =
        Chat.create_annotation(scope, app, %{question: "reset password?", answer: "Settings."})

      {:ok, updated} =
        Chat.update_annotation(scope, annotation.id, %{
          question: "how do I reset my password?",
          answer: "Settings → Reset."
        })

      assert updated.question == "how do I reset my password?"
      assert updated.answer == "Settings → Reset."

      {:ok, disabled} = Chat.update_annotation(scope, annotation.id, %{enabled: false})
      refute disabled.enabled

      assert {:error, :empty} =
               Chat.update_annotation(scope, annotation.id, %{question: "  ", answer: "x"})
    end
  end

  describe "batch cancel" do
    test "a canceled batch skips remaining rows and keeps its status", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Cancelable"})

      batch =
        Flux.Repo.insert!(%Workflows.WorkflowBatch{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          name: "to cancel",
          status: :running,
          graph: %{"nodes" => [], "edges" => []},
          rows: [%{"query" => "row1"}, %{"query" => "row2"}],
          total: 2
        })

      {:ok, canceled} = Workflows.cancel_batch(scope, batch.id)
      assert canceled.status == :canceled

      # The worker body respects the cancel: rows skip, status stays.
      assert :ok = Workflows.perform_batch(batch.id)
      reloaded = Flux.Repo.get!(Workflows.WorkflowBatch, batch.id, skip_workspace_guard: true)
      assert reloaded.status == :canceled
      assert Workflows.list_runs(scope, workflow.id) == []

      assert {:error, :not_running} = Workflows.cancel_batch(scope, batch.id)
    end
  end

  describe "flux-site passcode" do
    test "set, check, clear", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Gated Flux"})

      {:ok, workflow} = Workflows.set_site_passcode(scope, workflow, "88mph")
      assert workflow.site_passcode_hash != nil
      assert Workflows.site_passcode_ok?(workflow, "88mph")
      refute Workflows.site_passcode_ok?(workflow, "77mph")

      {:ok, cleared} = Workflows.set_site_passcode(scope, workflow, "")
      assert cleared.site_passcode_hash == nil
    end
  end

  defp wait_for_completion(message_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      case Flux.Repo.get!(Flux.Chat.Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end
end
