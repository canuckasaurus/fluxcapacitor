defmodule Flux.Batch23Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.ConversationEvals

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch23 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace, account: account}
  end

  describe "image generation" do
    test "the builtin images tool generates through the default provider and stores the file",
         %{scope: scope, workspace: workspace} do
      {:ok, _} = Flux.Providers.set_default_model(scope, "echo", "echo-1")

      assert {:ok, %{status: 200, body: stored, text: text}} =
               Flux.Tools.invoke_for_workspace(
                 workspace.id,
                 "builtin:images",
                 "generate_image",
                 %{
                   "prompt" => "a flux capacitor, glowing"
                 }
               )

      assert stored["name"] == "generated.png"
      assert text =~ stored["url"]

      file =
        Flux.Repo.get!(Flux.Chat.UploadedFile, stored["file_id"], skip_workspace_guard: true)

      assert file.content_type == "image/png"
      assert {:ok, "FAKE-PNG:" <> _prompt} = Flux.Storage.get(file.key)
    end

    test "no default provider refuses honestly", %{workspace: workspace} do
      assert {:error, message} =
               Flux.Tools.invoke_for_workspace(
                 workspace.id,
                 "builtin:images",
                 "generate_image",
                 %{
                   "prompt" => "anything"
                 }
               )

      assert message =~ "cannot generate images"
    end

    test "a blank prompt is refused", %{workspace: workspace} do
      assert {:error, message} =
               Flux.Tools.invoke_for_workspace(
                 workspace.id,
                 "builtin:images",
                 "generate_image",
                 %{}
               )

      assert message =~ "needs a prompt"
    end

    test "the builtin toolset appears in the picker list", %{scope: scope} do
      assert [%{id: "builtin:images", operations: [operation]}] =
               Flux.Tools.builtin_toolsets(scope)

      assert operation["operation_id"] == "generate_image"
    end
  end

  describe "conversation eval schedules" do
    setup %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Echo App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      Application.put_env(:flux, :eval_judge, fn _workspace_id, _messages ->
        {:ok, ~s({"score": 0.8, "reason": "fine"})}
      end)

      on_exit(fn -> Application.delete_env(:flux, :eval_judge) end)

      %{app: app}
    end

    test "an invalid cron is refused; a valid one arms the schedule", %{scope: scope, app: app} do
      assert {:error, changeset} =
               ConversationEvals.create_conversation_eval(scope, app, %{
                 "name" => "bad cron",
                 "expectation" => "n/a",
                 "turns" => ["hi"],
                 "schedule" => "not a cron"
               })

      assert %{schedule: [_reason]} = errors_on(changeset)

      assert {:ok, eval} =
               ConversationEvals.create_conversation_eval(scope, app, %{
                 "name" => "scheduled",
                 "expectation" => "answers politely",
                 "turns" => ["hello there"],
                 "schedule" => "* * * * *"
               })

      assert eval.schedule == "* * * * *"
    end

    test "run_scheduled runs due evals once per minute", %{scope: scope, app: app} do
      {:ok, eval} =
        ConversationEvals.create_conversation_eval(scope, app, %{
          "name" => "scheduled",
          "expectation" => "answers politely",
          "turns" => ["hello there"],
          "schedule" => "* * * * *"
        })

      now = DateTime.utc_now(:second)
      assert :ok = ConversationEvals.run_scheduled(now)

      ran = ConversationEvals.get_conversation_eval(scope, eval.id)
      assert ran.last_score == 0.8
      assert ran.last_run_at

      # Same minute → dedupe guard skips the second pass.
      assert :ok = ConversationEvals.run_scheduled(now)
      again = ConversationEvals.get_conversation_eval(scope, eval.id)
      assert again.last_run_at == ran.last_run_at
    end
  end

  describe "vision file loading" do
    test "fetch_image returns base64 for images and refuses other files", %{
      workspace: workspace
    } do
      {:ok, stored} =
        Flux.Workflows.store_run_output(workspace.id, "photo.png", <<137, 80, 78, 71>>)

      assert {:ok, %{data: data, media_type: "image/png"}} =
               Flux.Documents.fetch_image(workspace.id, stored["file_id"])

      assert Base.decode64!(data) == <<137, 80, 78, 71>>

      {:ok, text_file} = Flux.Workflows.store_run_output(workspace.id, "notes.txt", "hello")

      assert {:error, message} =
               Flux.Documents.fetch_image(workspace.id, text_file["file_id"])

      assert message =~ "not an image"
    end
  end
end
