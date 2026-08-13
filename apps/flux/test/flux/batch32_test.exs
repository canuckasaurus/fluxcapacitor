defmodule Flux.Batch32Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch32 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace}
  end

  defmodule ParamsCapture do
    @moduledoc false
    def invoke_llm(_plugin, _credentials, request, _emit) do
      send(self(), {:params, request.params})

      {:ok,
       %Flux.Plugin.ModelProvider.Result{
         content: "ok",
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end
  end

  describe "run tags" do
    test "normalize, start_run tags, set_run_tags, and the filter", %{scope: scope} do
      assert Workflows.normalize_run_tags(["  ci ", "ci", "", String.duplicate("x", 51)]) == [
               "ci"
             ]

      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Tagged Flux"})

      run =
        Flux.Repo.insert!(%Workflows.WorkflowRun{
          workspace_id: Flux.Accounts.Scope.workspace_id(scope),
          workflow_id: workflow.id,
          status: :succeeded
        })

      {:ok, tagged} = Workflows.set_run_tags(scope, run.id, ["nightly", "regression"])
      assert tagged.tags == ["nightly", "regression"]

      rows = Workflows.list_workspace_runs(scope, %{tag: "nightly"})
      assert Enum.any?(rows, &(&1.run.id == run.id))
      assert Workflows.list_workspace_runs(scope, %{tag: "absent"}) == []
    end
  end

  describe "message pinning" do
    test "toggle and list", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Pin App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, user_message, assistant} = Chat.send_message(scope, app, conversation, "pin me")
      wait_for_completion(assistant.id)

      {:ok, pinned} = Chat.toggle_pin_message(scope, user_message.id)
      assert pinned.pinned

      assert [%{id: pinned_id}] = Chat.pinned_messages(scope, conversation.id)
      assert pinned_id == user_message.id

      {:ok, unpinned} = Chat.toggle_pin_message(scope, user_message.id)
      refute unpinned.pinned
      assert Chat.pinned_messages(scope, conversation.id) == []
    end
  end

  describe "workspace default model params" do
    test "set, read, and merge under app params", %{scope: scope, workspace: workspace} do
      assert Accounts.default_model_params(workspace.id) == %{}

      {:ok, _workspace} = Accounts.set_default_model_params(scope, "0.3", "2048")
      assert Accounts.default_model_params(workspace.id) == %{temperature: 0.3, max_tokens: 2048}

      # An app's own params beat the workspace defaults; unset ones fall
      # through.
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Defaults App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1",
          "params" => %{"temperature" => 0.9}
        })

      previous = Application.get_env(:flux, :plugin_runtime)
      Application.put_env(:flux, :plugin_runtime, ParamsCapture)
      on_exit(fn -> Application.put_env(:flux, :plugin_runtime, previous) end)

      {:ok, _result, _model} =
        Chat.stateless_completion(app, [%{role: :user, content: "hi"}], fn _chunk -> :ok end)

      assert_receive {:params, params}
      assert params == %{temperature: 0.9, max_tokens: 2048}

      # Both blank turns the defaults off.
      {:ok, _workspace} = Accounts.set_default_model_params(scope, "", "")
      assert Accounts.default_model_params(workspace.id) == %{}
    end
  end

  describe "app icons" do
    test "cast and validated", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Icon App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1",
          "icon" => "⚡"
        })

      assert app.icon == "⚡"

      assert {:error, %Ecto.Changeset{}} =
               Chat.update_app(scope, app, %{"icon" => String.duplicate("x", 20)})
    end
  end

  describe "conversations CSV rows" do
    test "flattens completed messages with conversation context", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "CSV App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "web_abc"})
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "hello csv")
      wait_for_completion(assistant.id)

      rows = Chat.conversations_csv_rows(scope, app.id)
      assert Enum.any?(rows, &(&1.role == :user and &1.content == "hello csv"))
      assert Enum.all?(rows, &(&1.conversation_id == conversation.id))
      assert Enum.all?(rows, &(&1.end_user_ref == "web_abc"))
    end
  end

  describe "email triggers" do
    test "mint an emt_ token", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Mail Flux"})

      {:ok, trigger} =
        Workflows.create_trigger(scope, workflow, %{"type" => "email", "inputs" => %{}})

      assert trigger.type == :email
      assert String.starts_with?(trigger.token, "emt_")
      assert {:ok, %{type: :email}} = Workflows.fetch_trigger_by_token(trigger.token)
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
