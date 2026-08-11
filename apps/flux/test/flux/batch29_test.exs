defmodule Flux.Batch29Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch29 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace}
  end

  defmodule CapturingRuntime do
    @moduledoc false
    def invoke_llm(_plugin, _credentials, request, _emit) do
      send(self(), {:captured_request, request})

      {:ok,
       %Flux.Plugin.ModelProvider.Result{
         content: "ok",
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end
  end

  describe "workspace system prompt" do
    test "set, read, clear", %{scope: scope, workspace: workspace} do
      assert Accounts.workspace_system_prompt(scope) == nil

      {:ok, _} = Accounts.set_workspace_system_prompt(scope, "  Never give legal advice.  ")
      assert Accounts.workspace_system_prompt(scope) == "Never give legal advice."
      assert Accounts.system_prompt_for_workspace(workspace.id) == "Never give legal advice."

      {:ok, _} = Accounts.set_workspace_system_prompt(scope, "")
      assert Accounts.workspace_system_prompt(scope) == nil
    end

    test "prefixes the app prompt on stateless completions", %{scope: scope} do
      {:ok, _} = Accounts.set_workspace_system_prompt(scope, "Org rule: be brief.")

      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Prompted App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1",
          "system_prompt" => "You echo."
        })

      previous = Application.get_env(:flux, :plugin_runtime)
      Application.put_env(:flux, :plugin_runtime, CapturingRuntime)
      on_exit(fn -> Application.put_env(:flux, :plugin_runtime, previous) end)

      {:ok, _result, _model} =
        Chat.stateless_completion(app, [%{role: :user, content: "hi"}], fn _chunk -> :ok end)

      assert_receive {:captured_request, request}
      assert [%{role: :system, content: system} | _rest] = request.messages
      assert system == "Org rule: be brief.\n\nYou echo."
    end
  end

  describe "credential re-validate" do
    test "refreshes validated_at when the provider accepts", %{scope: scope} do
      {:ok, credential} = Flux.Providers.upsert_credential(scope, "echo", %{"note" => "x"})

      stale = DateTime.utc_now(:second) |> DateTime.add(-30, :day)

      credential =
        credential
        |> Ecto.Changeset.change(validated_at: stale)
        |> Flux.Repo.update!()

      assert {:ok, revalidated} = Flux.Providers.validate_credential(scope, credential.id)
      assert DateTime.compare(revalidated.validated_at, stale) == :gt
    end
  end

  describe "conversation purge" do
    test "purges only trashed conversations", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Purge App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{title: "doomed"})

      assert {:error, :not_found} = Chat.purge_conversation(scope, conversation.id)

      {:ok, _} = Chat.delete_conversation(scope, conversation.id)
      assert {:ok, _purged} = Chat.purge_conversation(scope, conversation.id)
      assert Chat.list_trashed_conversations(scope, app.id) == []
      assert {:error, :not_found} = Chat.get_conversation(scope, conversation.id)
    end
  end

  describe "mix flux.backup" do
    test "writes one archive per workspace", %{workspace: workspace} do
      dir =
        Path.join(System.tmp_dir!(), "flux-backup-test-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(dir) end)

      Mix.Tasks.Flux.Backup.run([dir])

      files = File.ls!(dir)
      assert Enum.any?(files, &String.contains?(&1, String.slice(workspace.id, 0, 8)))

      [file | _rest] = files
      payload = dir |> Path.join(file) |> File.read!() |> Jason.decode!()
      assert payload["format"] == "fluxcapacitor-workspace-export"
    end
  end
end
