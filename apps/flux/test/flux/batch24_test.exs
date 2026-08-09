defmodule Flux.Batch24Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.WorkspaceEnv

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch24 WS"})
    scope = Accounts.scope_for(account)

    %{scope: scope, workspace: workspace, account: account}
  end

  describe "workspace environment variables" do
    test "put/list/delete round trip with secret masking", %{scope: scope, workspace: workspace} do
      assert :ok = WorkspaceEnv.put(scope, "API_BASE", "https://api.example.com")
      assert :ok = WorkspaceEnv.put(scope, "API_KEY", "sk-secret", true)

      rows = WorkspaceEnv.list(scope)

      assert %{value: "https://api.example.com", is_secret: false} =
               Enum.find(rows, &(&1.name == "API_BASE"))

      # Secrets are write-only in the UI listing…
      assert %{value: nil, is_secret: true} = Enum.find(rows, &(&1.name == "API_KEY"))

      # …but resolve decrypted for runs.
      assert WorkspaceEnv.resolve(workspace.id) == %{
               "API_BASE" => "https://api.example.com",
               "API_KEY" => "sk-secret"
             }

      # Upsert replaces in place.
      assert :ok = WorkspaceEnv.put(scope, "API_BASE", "https://api2.example.com")
      assert WorkspaceEnv.resolve(workspace.id)["API_BASE"] == "https://api2.example.com"

      assert :ok = WorkspaceEnv.delete(scope, "API_KEY")
      refute Map.has_key?(WorkspaceEnv.resolve(workspace.id), "API_KEY")
    end

    test "bad names and blank values are refused", %{scope: scope} do
      assert {:error, :bad_name} = WorkspaceEnv.put(scope, "1BAD", "x")
      assert {:error, :bad_name} = WorkspaceEnv.put(scope, "has space", "x")
      assert {:error, :blank_value} = WorkspaceEnv.put(scope, "OK_NAME", "  ")
    end

    test "workspace env reaches runs as {{env.NAME}} with flux env winning", %{
      scope: scope,
      workspace: workspace
    } do
      assert :ok = WorkspaceEnv.put(scope, "GREETING", "howdy")
      assert :ok = WorkspaceEnv.put(scope, "SHADOWED", "workspace-level")

      {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Env Flux"})

      {:ok, workflow} =
        Flux.Workflows.update_draft(scope, workflow, %{
          "env" => %{"SHADOWED" => "flux-level"},
          "nodes" => [
            %{
              "id" => "start",
              "type" => "start",
              "title" => "Start",
              "config" => %{"variables" => []}
            },
            %{
              "id" => "template_1",
              "type" => "template",
              "title" => "T",
              "config" => %{"template" => "{{env.GREETING}} / {{env.SHADOWED}}"}
            },
            %{
              "id" => "end",
              "type" => "end",
              "title" => "End",
              "config" => %{
                "outputs" => [%{"key" => "text", "value" => "{{template_1.output}}"}]
              }
            }
          ],
          "edges" => [
            %{"id" => "e1", "source" => "start", "target" => "template_1"},
            %{"id" => "e2", "source" => "template_1", "target" => "end"}
          ]
        })

      {:ok, run} = Flux.Workflows.start_run(scope, workflow, %{})

      assert_receive {:run_finished, finished}, 10_000
      assert finished.id == run.id
      assert finished.status == :succeeded
      assert finished.outputs["text"] == "howdy / flux-level"
      _ = workspace
    end
  end

  describe "annotation import" do
    test "imports question/answer rows and skips malformed ones", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Ann App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      rows = [
        ["How do I reset?", "Settings → Reset."],
        ["What is the speed?", "88 mph."],
        # Malformed rows skip rather than failing the batch.
        ["lonely question"],
        ["", ""]
      ]

      assert {:ok, 2} = Chat.import_annotations(scope, app, rows)

      questions = Enum.map(Chat.list_annotations(scope, app.id), & &1.question)
      assert "How do I reset?" in questions
      assert "What is the speed?" in questions
    end
  end

  describe "stateless completion tool passthrough" do
    test "tools reach the provider and tool_calls come back", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Tools App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      tools = [
        %Flux.Plugin.ModelProvider.ToolDef{
          name: "get_weather",
          description: "Look up weather",
          parameters: %{"type" => "object", "properties" => %{}}
        }
      ]

      messages = [%{role: :user, content: "please call the tool for Paris"}]

      assert {:ok, result, "echo/echo-1"} =
               Chat.stateless_completion(app, messages, fn _chunk -> :ok end, tools: tools)

      assert [%{name: "get_weather", arguments: %{"echo" => _prompt}}] = result.tool_calls
    end
  end
end
