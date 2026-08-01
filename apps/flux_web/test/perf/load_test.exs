defmodule FluxWeb.Perf.LoadTest do
  @moduledoc """
  Load guard: seeds a corpus-scale workspace (10k segments, 1k
  conversations, 2k messages) and asserts the hot read paths stay inside
  generous bounds. Excluded by default — run with:

      mix test --include perf apps/flux_web/test/perf
  """
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts

  @moduletag :perf
  @moduletag timeout: 300_000

  @segments 10_000
  @conversations 1_000
  @dims 16

  test "retrieval, monitoring, and rollups stay fast at corpus scale" do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Perf WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "Perf App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    {:ok, dataset} =
      Flux.RAG.create_dataset(scope, %{
        "name" => "Perf KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    {seed_us, :ok} = :timer.tc(fn -> seed(workspace.id, app.id, dataset.id) end)

    {retrieve_us, {:ok, hits}} =
      :timer.tc(fn -> Flux.RAG.retrieve(scope, dataset.id, "vacation policy topic7") end)

    assert hits != []

    {monitor_us, _result} =
      :timer.tc(fn ->
        Flux.Chat.list_conversations(scope, app.id, 50)
        Flux.Chat.list_feedback(scope, app.id)
        Flux.Chat.search_messages(scope, app.id, "message 500")
      end)

    {usage_us, summary} = :timer.tc(fn -> Flux.Usage.workspace_summary(scope) end)
    assert summary.knowledge.segments == @segments

    {entities_us, _entities} = :timer.tc(fn -> Flux.RAG.list_entities(scope, dataset.id) end)

    IO.puts("""

    perf @ #{@segments} segments / #{@conversations} conversations:
      seed:            #{div(seed_us, 1000)} ms
      hybrid retrieve: #{div(retrieve_us, 1000)} ms
      monitor reads:   #{div(monitor_us, 1000)} ms
      usage rollup:    #{div(usage_us, 1000)} ms
      entity listing:  #{div(entities_us, 1000)} ms
    """)

    # Generous CI-safe ceilings — these catch order-of-magnitude
    # regressions, not micro-noise.
    assert retrieve_us < 5_000_000
    assert monitor_us < 3_000_000
    assert usage_us < 3_000_000
    assert entities_us < 2_000_000
  end

  defp seed(workspace_id, app_id, dataset_id) do
    now = DateTime.utc_now(:second)

    document_id = UUIDv7.generate()

    Flux.Repo.insert_all(
      Flux.RAG.Document,
      [
        %{
          id: document_id,
          workspace_id: workspace_id,
          dataset_id: dataset_id,
          name: "corpus.md",
          status: :ready,
          segment_count: @segments,
          inserted_at: now,
          updated_at: now
        }
      ],
      skip_workspace_guard: true
    )

    0..(@segments - 1)
    |> Enum.map(fn index ->
      %{
        id: UUIDv7.generate(),
        workspace_id: workspace_id,
        dataset_id: dataset_id,
        document_id: document_id,
        position: index,
        content:
          "Segment #{index} covers topic#{rem(index, 50)} including vacation " <>
            "policy details and payroll notes for Acme Corp.",
        embedding: vector(index),
        enabled: true,
        inserted_at: now
      }
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      Flux.Repo.insert_all(Flux.RAG.Segment, chunk, skip_workspace_guard: true)
    end)

    conversations =
      for index <- 1..@conversations do
        %{
          id: UUIDv7.generate(),
          workspace_id: workspace_id,
          app_id: app_id,
          title: "Conversation #{index}",
          inserted_at: now,
          updated_at: now
        }
      end

    conversations
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      Flux.Repo.insert_all(Flux.Chat.Conversation, chunk, skip_workspace_guard: true)
    end)

    conversations
    |> Enum.with_index()
    |> Enum.flat_map(fn {conversation, index} ->
      [
        %{
          id: UUIDv7.generate(),
          workspace_id: workspace_id,
          conversation_id: conversation.id,
          role: :user,
          content: "User message #{index} about topic#{rem(index, 50)}",
          status: :completed,
          inserted_at: now,
          updated_at: now
        },
        %{
          id: UUIDv7.generate(),
          workspace_id: workspace_id,
          conversation_id: conversation.id,
          role: :assistant,
          content: "Assistant message #{index}",
          status: :completed,
          usage: %{"input_tokens" => 10, "output_tokens" => 20},
          feedback: (rem(index, 10) == 0 && :like) || nil,
          inserted_at: now,
          updated_at: now
        }
      ]
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      Flux.Repo.insert_all(Flux.Chat.Message, chunk, skip_workspace_guard: true)
    end)

    :ok
  end

  defp vector(index) do
    for dim <- 1..@dims, do: :math.sin(index * dim * 0.1)
  end
end
