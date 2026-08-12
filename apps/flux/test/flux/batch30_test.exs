defmodule Flux.Batch30Test do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch30 WS"})
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

  describe "model params round-out" do
    test "stop and penalties survive the whitelist", %{scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Params App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1",
          "params" => %{
            "temperature" => 0.2,
            "stop" => ["END"],
            "frequency_penalty" => 0.5,
            "seed" => 42,
            "made_up_key" => "dropped"
          }
        })

      previous = Application.get_env(:flux, :plugin_runtime)
      Application.put_env(:flux, :plugin_runtime, ParamsCapture)
      on_exit(fn -> Application.put_env(:flux, :plugin_runtime, previous) end)

      {:ok, _result, _model} =
        Chat.stateless_completion(app, [%{role: :user, content: "hi"}], fn _chunk -> :ok end)

      assert_receive {:params, params}
      assert params == %{temperature: 0.2, stop: ["END"], frequency_penalty: 0.5, seed: 42}
    end
  end

  describe "failed-run auto-retry" do
    defp broken_graph do
      %{
        "nodes" => [
          %{
            "id" => "start",
            "type" => "start",
            "title" => "Start",
            "config" => %{"variables" => []}
          },
          %{
            "id" => "llm_1",
            "type" => "llm",
            "title" => "Broken",
            "config" => %{"provider_plugin_id" => "nope", "model" => "ghost", "prompt" => "x"}
          },
          %{
            "id" => "end",
            "type" => "end",
            "title" => "End",
            "config" => %{"outputs" => [%{"key" => "r", "value" => "{{llm_1.text}}"}]}
          }
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "llm_1"},
          %{"id" => "e2", "source" => "llm_1", "target" => "end"}
        ]
      }
    end

    test "opted-in fluxes get exactly one second attempt", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Retry Flux"})
      {:ok, workflow} = Workflows.update_draft(scope, workflow, broken_graph())
      {:ok, workflow} = Workflows.update_workflow(scope, workflow, %{"auto_retry" => true})
      assert workflow.auto_retry

      {:ok, run} = Workflows.start_run(scope, workflow, %{})
      assert_receive {:run_finished, _first}, 10_000

      # The retry broadcasts on its own run topic — poll for it instead.
      runs =
        Enum.reduce_while(1..50, [], fn _attempt, _acc ->
          runs = Workflows.list_runs(scope, workflow.id)

          if length(runs) == 2 and Enum.all?(runs, &(&1.status != :running)) do
            {:halt, runs}
          else
            Process.sleep(100)
            {:cont, runs}
          end
        end)

      assert length(runs) == 2
      assert Enum.any?(runs, &(&1.retry_of_id == run.id))
      assert Enum.all?(runs, &(&1.status == :failed))
    end

    test "without the toggle a failure stays a single run", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "No Retry"})
      {:ok, workflow} = Workflows.update_draft(scope, workflow, broken_graph())

      {:ok, _run} = Workflows.start_run(scope, workflow, %{})
      assert_receive {:run_finished, _first}, 10_000

      assert length(Workflows.list_runs(scope, workflow.id)) == 1
    end
  end

  describe "audit webhook events" do
    test "audit.recorded reaches subscribed endpoints", %{scope: scope} do
      {:ok, _endpoint} =
        Flux.Webhooks.create_endpoint(scope, %{
          "url" => "https://hooks.example.com/siem",
          "events" => ["audit.recorded"]
        })

      {:ok, _app} =
        Chat.create_app(scope, %{
          "name" => "Audited App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      deliveries = Flux.Webhooks.list_deliveries(scope)
      assert delivery = Enum.find(deliveries, &(&1.event == "audit.recorded"))
      assert delivery.payload["action"] == "app.create"
    end
  end

  describe "storage rollup" do
    test "instance overview sums stored bytes per workspace", %{workspace: workspace} do
      {:ok, _stored} =
        Workflows.store_run_output(workspace.id, "big.txt", String.duplicate("x", 2048))

      row = Enum.find(Accounts.instance_overview(), &(&1.workspace.id == workspace.id))
      assert row.storage_bytes >= 2048
    end
  end

  describe "eval set copy" do
    test "copies the set and cases to another flux", %{scope: scope} do
      {:ok, source} = Workflows.create_workflow(scope, %{"name" => "Source Flux"})
      {:ok, target} = Workflows.create_workflow(scope, %{"name" => "Target Flux"})

      {:ok, set} = Flux.Evals.create_set(scope, source, %{"name" => "Goldens"})

      {:ok, _case} =
        Flux.Evals.add_case(scope, set, %{
          "inputs" => %{"query" => "q"},
          "expected" => "a",
          "weight" => 2.0
        })

      {:ok, copied} = Flux.Evals.copy_set(scope, set.id, target.id)
      assert copied.name == "Goldens (copy)"
      assert copied.workflow_id == target.id

      assert [%{expected: "a", weight: 2.0}] = Flux.Evals.list_cases(scope, copied.id)
    end
  end
end
