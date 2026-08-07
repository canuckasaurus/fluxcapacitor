defmodule FluxWeb.Perf.ConcurrencyBenchTest do
  @moduledoc """
  Round-2 load guard: many chat sessions streaming at once, and batch
  throughput over a wide row set. Excluded by default — run with:

      mix test --include perf apps/flux_web/test/perf
  """
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  @moduletag :perf
  @moduletag timeout: 300_000

  @sessions 50
  @batch_rows 100

  test "concurrent chat sessions all stream to completion" do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Concurrency WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Bench App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {elapsed_us, results} =
      :timer.tc(fn ->
        1..@sessions
        |> Enum.map(fn index ->
          Task.async(fn ->
            conversation = Chat.create_conversation(scope, app)

            {:ok, _user, _assistant} =
              Chat.send_message(scope, app, conversation, "session #{index} says hi")

            receive do
              {:done, final} -> final.status
            after
              30_000 -> :timeout
            end
          end)
        end)
        |> Task.await_many(60_000)
      end)

    assert Enum.all?(results, &(&1 == :completed))

    per_session = div(elapsed_us, @sessions * 1000)

    IO.puts("""

    perf round 2 @ #{@sessions} concurrent chat sessions:
      wall clock:  #{div(elapsed_us, 1000)} ms
      per session: #{per_session} ms (amortized)
    """)

    # Order-of-magnitude ceiling, not micro-noise.
    assert elapsed_us < 60_000_000
  end

  test "batch throughput over #{@batch_rows} rows" do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Batch Bench WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Bench Flux"})
    {:ok, workflow} = Workflows.update_draft(scope, workflow, echo_graph())

    rows = for index <- 1..@batch_rows, do: %{"query" => "row #{index}"}
    {:ok, batch} = Workflows.start_batch(scope, workflow, rows, name: "bench.csv")

    {elapsed_us, :ok} = :timer.tc(fn -> Workflows.perform_batch(batch.id) end)

    finished = Workflows.get_batch(scope, batch.id)
    assert finished.status == :completed
    assert finished.succeeded == @batch_rows

    rows_per_second = @batch_rows * 1_000_000 / max(elapsed_us, 1)

    IO.puts("""

    perf round 2 @ #{@batch_rows}-row batch:
      wall clock: #{div(elapsed_us, 1000)} ms
      throughput: #{Float.round(rows_per_second, 1)} rows/s
    """)

    assert elapsed_us < 120_000_000
  end

  defp echo_graph do
    %{
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
  end
end
