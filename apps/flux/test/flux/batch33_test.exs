defmodule Flux.Batch33Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch33 WS"})
    scope = Accounts.scope_for(account)

    %{account: account, scope: scope, workspace: workspace}
  end

  describe "run attribution" do
    test "console runs carry the account email; explicit starters win", %{
      account: account,
      scope: scope
    } do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Attributed"})

      graph =
        update_in(workflow.graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")

            node ->
              node
          end)
        end)

      {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)

      {:ok, run} = Workflows.start_run(scope, workflow, %{"query" => "who started me?"})
      assert run.started_by == account.email

      {:ok, tagged_run} =
        Workflows.start_run(scope, workflow, %{"query" => "x"}, started_by: "api:app-abc…")

      assert tagged_run.started_by == "api:app-abc…"

      wait_for_finish(scope, run.id)
      wait_for_finish(scope, tagged_run.id)
    end
  end

  describe "audit retention" do
    test "only opted-in workspaces prune, and only past the window", %{
      scope: scope,
      workspace: workspace
    } do
      # Two entries: one ancient, one fresh.
      Flux.Audit.record(scope, "test.old")
      Flux.Audit.record(scope, "test.fresh")

      ancient = DateTime.utc_now(:second) |> DateTime.add(-90, :day)

      from(e in Flux.Audit.Entry,
        where: e.workspace_id == ^workspace.id and e.action == "test.old"
      )
      |> Repo.update_all([set: [inserted_at: ancient]], skip_workspace_guard: true)

      # No policy: the sweep leaves audit alone.
      assert :ok = perform_cleanup()
      assert audit_count(workspace.id) == 2

      # With a 60-day policy the ancient entry goes, the fresh one stays.
      {:ok, _workspace} = Accounts.set_audit_retention_days(scope, 60)
      assert :ok = perform_cleanup()
      assert audit_count(workspace.id) == 1

      # Clearing the policy turns pruning back off.
      {:ok, _workspace} = Accounts.set_audit_retention_days(scope, nil)
      assert Accounts.audit_retention_days(scope) == nil
    end
  end

  describe "session validity" do
    test "the config override shortens the window", %{account: account} do
      token = Accounts.generate_account_session_token(account)

      # Backdate the session five days.
      stale = NaiveDateTime.utc_now() |> NaiveDateTime.add(-5, :day)

      from(t in Flux.Accounts.AccountToken, where: t.token == ^token)
      |> Repo.update_all(set: [inserted_at: stale])

      # Default window (14 days): still valid.
      assert {%Accounts.Account{}, _inserted_at} = Accounts.get_account_by_session_token(token)

      # Tightened to 3 days: the same session is now expired.
      Application.put_env(:flux, :session_validity_days, 3)
      on_exit(fn -> Application.delete_env(:flux, :session_validity_days) end)

      assert Accounts.get_account_by_session_token(token) == nil
    end
  end

  defp perform_cleanup do
    Flux.Workflows.CleanupWorker.perform(%Oban.Job{})
  end

  defp audit_count(workspace_id) do
    from(e in Flux.Audit.Entry,
      where: e.workspace_id == ^workspace_id and like(e.action, "test.%")
    )
    |> Repo.aggregate(:count, skip_workspace_guard: true)
  end

  defp wait_for_finish(scope, run_id) do
    Enum.reduce_while(1..50, nil, fn _try, acc ->
      case Workflows.get_run(scope, run_id) do
        %{status: :running} -> Process.sleep(100) && {:cont, acc}
        %{} = run -> {:halt, run}
        _error -> {:halt, acc}
      end
    end)
  end
end
