defmodule FluxWeb.Batch23WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch23 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "GET /v1/models (OpenAI-compatible)" do
    test "lists the app's model first, then provider models", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Models App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/models")
        |> json_response(200)

      assert body["object"] == "list"

      assert [%{"id" => "echo-1", "object" => "model", "owned_by" => "echo"} | _rest] =
               body["data"]

      # The echo provider's own catalog rides along for autodiscovery.
      assert Enum.all?(body["data"], &(&1["object"] == "model"))
    end

    test "the registry keeps working at its new path", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Registry App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/registry/models")
        |> json_response(200)

      assert body["data"] == []
    end
  end

  describe "instance announcement banner" do
    test "shows atop console pages while set, gone when cleared", %{conn: conn, account: account} do
      :ok = Flux.InstanceSettings.put("announcement", "Maintenance Saturday 02:00 UTC.")
      on_exit(fn -> Flux.InstanceSettings.put("announcement", "") end)

      response =
        conn
        |> log_in_account(account)
        |> get(~p"/console")
        |> html_response(200)

      assert response =~ "instance-announcement"
      assert response =~ "Maintenance Saturday 02:00 UTC."

      :ok = Flux.InstanceSettings.put("announcement", "")

      response =
        build_conn()
        |> log_in_account(account)
        |> get(~p"/console")
        |> html_response(200)

      refute response =~ "instance-announcement"
    end
  end

  describe "subflux call node end to end" do
    test "a parent flux calls a published sub-flux with mapped inputs", %{scope: scope} do
      {:ok, sub} = Flux.Workflows.create_workflow(scope, %{"name" => "Greeter"})

      {:ok, sub} =
        Flux.Workflows.update_draft(scope, sub, %{
          "nodes" => [
            %{
              "id" => "start",
              "type" => "start",
              "title" => "Start",
              "config" => %{
                "variables" => [
                  %{"name" => "who", "label" => "Who", "type" => "text", "required" => true}
                ]
              }
            },
            %{
              "id" => "template_1",
              "type" => "template",
              "title" => "Greet",
              "config" => %{"template" => "hello {{start.who}}", "mode" => "simple"}
            },
            %{
              "id" => "end",
              "type" => "end",
              "title" => "End",
              "config" => %{
                "outputs" => [%{"key" => "greeting", "value" => "{{template_1.output}}"}]
              }
            }
          ],
          "edges" => [
            %{"id" => "e1", "source" => "start", "target" => "template_1"},
            %{"id" => "e2", "source" => "template_1", "target" => "end"}
          ]
        })

      {:ok, _version} = Flux.Workflows.publish(scope, sub)

      {:ok, parent} = Flux.Workflows.create_workflow(scope, %{"name" => "Caller"})

      {:ok, parent} =
        Flux.Workflows.update_draft(scope, parent, %{
          "nodes" => [
            %{
              "id" => "start",
              "type" => "start",
              "title" => "Start",
              "config" => %{
                "variables" => [
                  %{"name" => "name", "label" => "Name", "type" => "text", "required" => true}
                ]
              }
            },
            %{
              "id" => "sub_1",
              "type" => "subflux",
              "title" => "Call greeter",
              "config" => %{
                "workflow_id" => sub.id,
                "inputs" => %{"who" => "{{start.name}}"}
              }
            },
            %{
              "id" => "end",
              "type" => "end",
              "title" => "End",
              "config" => %{
                "outputs" => [%{"key" => "result", "value" => "{{sub_1.greeting}}"}]
              }
            }
          ],
          "edges" => [
            %{"id" => "e1", "source" => "start", "target" => "sub_1"},
            %{"id" => "e2", "source" => "sub_1", "target" => "end"}
          ]
        })

      {:ok, run} = Flux.Workflows.start_run(scope, parent, %{"name" => "Marty"})

      assert_receive {:run_finished, finished}, 10_000
      assert finished.id == run.id
      assert finished.status == :succeeded
      assert finished.outputs["result"] == "hello Marty"
    end
  end

  describe "bulk document operations" do
    setup %{scope: scope} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Bulk DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      docs =
        for name <- ~w(a.md b.md c.md) do
          {:ok, doc} =
            Flux.RAG.add_document(scope, dataset, %{name: name, content: "text " <> name})

          doc
        end

      Oban.drain_queue(queue: :ingest)

      %{dataset: dataset, docs: docs}
    end

    test "disable cascades to segments and retrieval skips them; enable restores", %{
      scope: scope,
      dataset: dataset,
      docs: [doc_a, doc_b, _doc_c]
    } do
      ids = [doc_a.id, doc_b.id]

      assert {:ok, 2} = Flux.RAG.set_documents_enabled(scope, ids, false)

      documents = Flux.RAG.list_documents(scope, dataset.id)
      assert Enum.count(documents, & &1.enabled) == 1

      segments = Flux.RAG.list_segments(scope, doc_a.id)
      assert Enum.all?(segments, &(&1.enabled == false))

      {:ok, hits} = Flux.RAG.retrieve(scope, dataset.id, "text a.md")
      refute Enum.any?(hits, &(&1.document_id == doc_a.id))

      assert {:ok, 2} = Flux.RAG.set_documents_enabled(scope, ids, true)
      {:ok, hits} = Flux.RAG.retrieve(scope, dataset.id, "text a.md")
      assert Enum.any?(hits, &(&1.document_id == doc_a.id))
    end

    test "bulk tag merges and bulk delete removes", %{
      scope: scope,
      dataset: dataset,
      docs: [doc_a, doc_b, doc_c]
    } do
      assert {:ok, 2} = Flux.RAG.tag_documents(scope, [doc_a.id, doc_b.id], ["Legal", "eu "])

      tagged = Flux.RAG.list_documents(scope, dataset.id)
      assert Enum.count(tagged, &("legal" in &1.tags)) == 2

      assert {:ok, 2} = Flux.RAG.delete_documents(scope, [doc_a.id, doc_c.id])
      assert [%{id: remaining_id}] = Flux.RAG.list_documents(scope, dataset.id)
      assert remaining_id == doc_b.id
    end
  end
end
