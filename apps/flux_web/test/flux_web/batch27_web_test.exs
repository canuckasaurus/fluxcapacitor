defmodule FluxWeb.Batch27WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch27 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "batch outputs into a dataset" do
    test "successful rows land as documents", %{scope: scope, workspace: workspace} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Gen Flux"})

      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Landing DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      batch =
        Flux.Repo.insert!(%Workflows.WorkflowBatch{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          name: "gen",
          graph: %{"nodes" => [], "edges" => []},
          status: :completed,
          total: 3,
          succeeded: 2,
          failed: 1
        })

      for {status, outputs} <- [
            {:succeeded, %{"answer" => "generated summary one"}},
            {:succeeded, %{"result" => "generated summary two"}},
            {:failed, %{}}
          ] do
        Flux.Repo.insert!(%Workflows.WorkflowRun{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          batch_id: batch.id,
          status: status,
          source: :batch,
          outputs: outputs
        })
      end

      assert {:ok, 2} = Workflows.export_batch_to_dataset(scope, batch.id, dataset.id)

      Oban.drain_queue(queue: :ingest)
      documents = Flux.RAG.list_documents(scope, dataset.id)

      assert length(documents) == 2
      assert Enum.any?(documents, &(&1.content == "generated summary one"))
      assert Enum.all?(documents, &(&1.name =~ "gen — row"))
    end
  end

  describe "GET /v1/visitors" do
    test "answers the per-visitor rollup on app tokens", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Visitors App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app, %{end_user_ref: "api-visitor"})
      {:ok, _user, _assistant} = Chat.send_message(scope, app, conversation, "hello stats")
      assert_receive {:done, _reply}, 5_000

      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/visitors")
        |> json_response(200)

      assert [visitor] = body["data"]
      assert visitor["ref"] == "api-visitor"
      assert visitor["messages"] == 2
      assert is_integer(visitor["last_seen"])
    end
  end
end
