defmodule Flux.Workflows.CopilotTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows.Copilot

  # The fake model: each test hands it a fun via the process dictionary
  # (Copilot.draft runs synchronously in the caller).
  defmodule FakeModel do
    def generate(messages), do: Process.get(:copilot_fun).(messages)
  end

  setup do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Copilot WS"})
    scope = Accounts.scope_for(account)

    Application.put_env(:flux, Copilot, module: FakeModel)
    on_exit(fn -> Application.delete_env(:flux, Copilot) end)

    %{scope: scope}
  end

  @good_graph %{
    "name" => "Greeter",
    "nodes" => [
      %{
        "id" => "start",
        "type" => "start",
        "title" => "Start",
        "config" => %{
          "variables" => [
            %{"name" => "query", "label" => "Query", "type" => "text", "required" => true}
          ]
        }
      },
      %{
        "id" => "t",
        "type" => "template",
        "title" => "Greet",
        "config" => %{"template" => "Hello {{start.query}}"}
      },
      %{
        "id" => "end",
        "type" => "end",
        "title" => "End",
        "config" => %{"outputs" => [%{"key" => "greeting", "value" => "{{t.output}}"}]}
      }
    ],
    "edges" => [
      %{"source" => "start", "source_handle" => "default", "target" => "t"},
      %{"source" => "t", "source_handle" => "default", "target" => "end"}
    ]
  }

  test "drafts a validated graph with auto layout", %{scope: scope} do
    Process.put(:copilot_fun, fn _messages -> {:ok, Jason.encode!(@good_graph)} end)

    assert {:ok, %{name: "Greeter", graph: graph, warnings: []}} =
             Copilot.draft(scope, "greet the user")

    assert length(graph["nodes"]) == 3
    assert Enum.all?(graph["nodes"], &match?(%{"position" => %{"x" => _, "y" => _}}, &1))
    assert [%{"id" => "edge_1"} | _] = graph["edges"]
  end

  test "unwraps markdown fences and prose around the JSON", %{scope: scope} do
    Process.put(:copilot_fun, fn _messages ->
      {:ok, "Here you go!\n```json\n" <> Jason.encode!(@good_graph) <> "\n```\nEnjoy."}
    end)

    assert {:ok, %{name: "Greeter"}} = Copilot.draft(scope, "greet the user")
  end

  test "one corrective retry when the first graph fails the engine", %{scope: scope} do
    broken = put_in(@good_graph["edges"], [%{"source" => "start", "target" => "ghost"}])

    Process.put(:copilot_fun, fn messages ->
      if Enum.any?(messages, &(&1.content =~ "failed validation")) do
        {:ok, Jason.encode!(@good_graph)}
      else
        {:ok, Jason.encode!(broken)}
      end
    end)

    assert {:ok, %{name: "Greeter"}} = Copilot.draft(scope, "greet the user")
  end

  test "gives up honestly after the retry", %{scope: scope} do
    Process.put(:copilot_fun, fn _messages -> {:ok, "I cannot help with that."} end)

    assert {:error, message} = Copilot.draft(scope, "greet the user")
    assert message =~ "could not produce a valid flux"
  end

  test "rejects a blank description", %{scope: scope} do
    assert {:error, message} = Copilot.draft(scope, "   ")
    assert message =~ "Describe"
  end

  test "without a fake and without a default model, points at Plugins", %{scope: scope} do
    Application.delete_env(:flux, Copilot)

    assert {:error, message} = Copilot.draft(scope, "greet the user")
    assert message =~ "default model"
  end

  test "reference warnings surface without blocking the draft", %{scope: scope} do
    dangling =
      put_in(
        @good_graph["nodes"],
        List.update_at(@good_graph["nodes"], 1, fn node ->
          put_in(node["config"]["template"], "Hello {{missing.output}}")
        end)
      )

    Process.put(:copilot_fun, fn _messages -> {:ok, Jason.encode!(dangling)} end)

    assert {:ok, %{warnings: [_ | _]}} = Copilot.draft(scope, "greet the user")
  end
end
