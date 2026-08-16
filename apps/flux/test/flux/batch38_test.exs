defmodule Flux.Batch38Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch38 WS"})
    scope = Accounts.scope_for(account)

    %{account: Accounts.get_account!(account.id), scope: scope, workspace: workspace}
  end

  defp echo_app(scope, extra \\ %{}) do
    {:ok, app} =
      Chat.create_app(
        scope,
        Map.merge(
          %{"name" => "B38 App", "provider_plugin_id" => "echo", "model" => "echo-1"},
          extra
        )
      )

    app
  end

  defp wait_for_completion(message_id) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      case Flux.Repo.get!(Flux.Chat.Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
        done -> {:halt, done}
      end
    end)
  end

  describe "session idle timeout" do
    test "an idle session dies; an active one lives", %{account: account} do
      token = Accounts.generate_account_session_token(account)
      assert {%{id: id}, _inserted_at} = Accounts.get_account_by_session_token(token)
      assert id == account.id

      Application.put_env(:flux, :session_idle_minutes, 30)
      on_exit(fn -> Application.delete_env(:flux, :session_idle_minutes) end)

      # Still within the window.
      assert {_account, _inserted_at} = Accounts.get_account_by_session_token(token)

      # Backdate both clocks past the idle window: dead.
      old = DateTime.add(DateTime.utc_now(:second), -45, :minute)

      Flux.Repo.update_all(
        from(t in Flux.Accounts.AccountToken, where: t.context == "session"),
        set: [last_used_at: old, inserted_at: DateTime.to_naive(old)]
      )

      assert Accounts.get_account_by_session_token(token) == nil
    end

    test "session use advances the idle clock", %{account: account} do
      Application.put_env(:flux, :session_idle_minutes, 30)
      on_exit(fn -> Application.delete_env(:flux, :session_idle_minutes) end)

      token = Accounts.generate_account_session_token(account)

      # Make the touch throttle see a stale clock, then use the session.
      old = DateTime.add(DateTime.utc_now(:second), -20, :minute)

      Flux.Repo.update_all(
        from(t in Flux.Accounts.AccountToken, where: t.context == "session"),
        set: [last_used_at: old]
      )

      assert {_account, _inserted_at} = Accounts.get_account_by_session_token(token)

      [refreshed] =
        Flux.Repo.all(from(t in Flux.Accounts.AccountToken, where: t.context == "session"))

      assert DateTime.compare(refreshed.last_used_at, old) == :gt
    end
  end

  describe "chat document uploads" do
    test "extracted text rides into the model's context", %{scope: scope} do
      app = echo_app(scope)

      path = Path.join(System.tmp_dir!(), "b38-manual-#{System.unique_integer([:positive])}.md")
      File.write!(path, "The flux capacitor needs 1.21 gigawatts.")
      on_exit(fn -> File.rm(path) end)

      {:ok, file} =
        Chat.create_upload(scope, app, %{
          path: path,
          filename: "manual.md",
          content_type: "text/markdown"
        })

      assert file.extracted_text =~ "1.21 gigawatts"

      conversation = Chat.create_conversation(scope, app)

      {:ok, _user, assistant} =
        Chat.send_message(scope, app, conversation, "what does the doc say?", files: [file])

      done = wait_for_completion(assistant.id)
      assert done.status == :completed
      # The echo provider replays the turn it saw — document text included.
      assert done.content =~ "1.21 gigawatts"
      assert done.content =~ "manual.md"
    end

    test "images are left to the vision path", %{scope: scope} do
      app = echo_app(scope)

      path = Path.join(System.tmp_dir!(), "b38-pix-#{System.unique_integer([:positive])}.png")
      File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0>>)
      on_exit(fn -> File.rm(path) end)

      {:ok, file} =
        Chat.create_upload(scope, app, %{
          path: path,
          filename: "pix.png",
          content_type: "image/png"
        })

      assert file.extracted_text == nil
    end
  end

  describe "dataset-scoped API keys" do
    test "mint, resolve, and stay out of the workspace token list", %{scope: scope} do
      # The dataset id is a plain field on the token (the Dataset schema
      # lives in flux_rag) — any id works for the token round-trip.
      dataset_id = Ecto.UUID.generate()

      {:ok, token, raw} = Chat.create_dataset_token(scope, dataset_id)
      assert String.starts_with?(raw, "ds-")
      assert token.dataset_id == dataset_id

      assert {:ok, resolved_id, workspace_id, _token} = Chat.fetch_dataset_by_token(raw)
      assert resolved_id == dataset_id
      assert workspace_id == Flux.Accounts.Scope.workspace_id(scope)

      assert {:error, :invalid_token} = Chat.fetch_dataset_by_token("ds-nope")

      # Workspace token listing keeps its kind pure.
      {:ok, _ws_token, _ws_raw} = Chat.create_workspace_token(scope)
      kinds = Chat.list_workspace_tokens(scope)
      assert Enum.all?(kinds, &is_nil(&1.dataset_id))
    end
  end

  describe "flux and app tags" do
    test "cast, persist, and read back", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Tagged Flux"})
      {:ok, tagged} = Workflows.update_workflow(scope, workflow, %{"tags" => ["etl", "prod"]})
      assert tagged.tags == ["etl", "prod"]

      app = echo_app(scope)
      {:ok, tagged_app} = Chat.update_app(scope, app, %{"tags" => ["support"]})
      assert tagged_app.tags == ["support"]
    end
  end

  describe "OIDC claim→role mapping" do
    test "roles follow the claim; owners and unmatched stay put", %{
      scope: scope,
      workspace: workspace
    } do
      member = account_fixture()
      {:ok, _membership} = Accounts.scim_provision(workspace, member.email)

      {:ok, _workspace} =
        Accounts.set_oidc_role_mapping(scope, "groups", %{
          "builders" => "editor",
          "ops" => "admin"
        })

      :ok = Accounts.apply_oidc_roles(member, %{"groups" => ["builders", "unrelated"]})
      assert Accounts.scim_find_member(workspace.id, member.id).role == :editor

      # Unmatched values leave the role alone.
      :ok = Accounts.apply_oidc_roles(member, %{"groups" => ["strangers"]})
      assert Accounts.scim_find_member(workspace.id, member.id).role == :editor

      # The owner never moves, whatever the claims say.
      :ok = Accounts.apply_oidc_roles(scope.account, %{"groups" => ["builders"]})
      assert Accounts.scim_find_member(workspace.id, scope.account.id).role == :owner
    end
  end

  describe "scheduled backups" do
    test "runs once per day after 03:00, writing through storage", %{} do
      Application.put_env(:flux, :scheduled_backups, true)
      on_exit(fn -> Application.delete_env(:flux, :scheduled_backups) end)
      Flux.InstanceSettings.put("backup_last_date", "")

      early = DateTime.new!(~D[2026-08-20], ~T[01:00:00], "Etc/UTC")
      assert :ok = Flux.Backup.run_scheduled(early)
      assert Flux.InstanceSettings.get("backup_last_date") != "2026-08-20"

      due = DateTime.new!(~D[2026-08-20], ~T[03:30:00], "Etc/UTC")
      assert :ok = Flux.Backup.run_scheduled(due)
      assert Flux.InstanceSettings.get("backup_last_date") == "2026-08-20"

      # Direct run reports per-workspace results.
      assert {:ok, %{ok: ok, failed: 0}} = Flux.Backup.run_to_storage("test-label")
      assert ok >= 1
    end
  end

  describe "OpenAPI toolset from URL" do
    test "an unreachable URL surfaces an honest error", %{scope: scope} do
      assert {:error, _message} =
               Flux.Tools.import_toolset_from_url(scope, "http://127.0.0.1:9/openapi.json")
    end
  end
end
