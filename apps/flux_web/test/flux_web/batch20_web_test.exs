defmodule FluxWeb.Batch20WebTest do
  @moduledoc "Batch-20 web surfaces: status page, shared traces, SVG, monitor CSV, metadata."
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "B20 Web WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope, workspace: workspace, account: account}
  end

  test "the status page answers HTML and JSON without auth", %{workspace: _workspace} do
    :ok = Flux.InstanceSettings.put("status_note", "Planned maintenance tonight.")

    html_conn = get(build_conn(), ~p"/status")
    html = html_response(html_conn, 200)
    assert html =~ "database"
    assert html =~ "Planned maintenance tonight."

    json_conn = get(build_conn(), "/status/json")
    body = json_response(json_conn, 200)
    assert body["note"] == "Planned maintenance tonight."
    assert Enum.any?(body["components"], &(&1["name"] == "database" and &1["state"] == "ok"))
  end

  test "shared run traces open read-only by token and refuse bad tokens", %{
    scope: scope
  } do
    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Shared Flux"})
    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, echo_graph())
    {:ok, run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "share me"})
    assert_receive {:run_finished, _finished}, 5_000

    token = FluxWeb.RunShareController.sign(run.id)

    # No login needed.
    conn = get(build_conn(), ~p"/share/runs/#{token}")
    html = html_response(conn, 200)
    assert html =~ "Shared Flux"
    assert html =~ "read-only"
    assert html =~ "share me"

    assert build_conn() |> get(~p"/share/runs/not-a-token") |> html_response(404)
  end

  test "the flux canvas downloads as SVG", %{conn: conn, scope: scope} do
    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Drawn Flux"})

    conn = get(conn, ~p"/console/fluxes/#{workflow.id}/svg")
    assert response_content_type(conn, :svg) =~ "image/svg"
    assert conn.resp_body =~ "<svg"
    # The starter graph's nodes render as boxes with titles.
    assert conn.resp_body =~ "Start"
  end

  test "monitor tables download as CSV", %{conn: conn, scope: scope} do
    {:ok, app} =
      Flux.Chat.create_app(scope, %{
        "name" => "CSV App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    conversation = Flux.Chat.create_conversation(scope, app)
    {:ok, _u, assistant} = Flux.Chat.send_message(scope, app, conversation, "rate me")
    assert_receive {:done, _}, 5_000
    {:ok, _} = Flux.Chat.set_feedback(scope, assistant.id, :like)

    feedback_conn = get(conn, ~p"/console/apps/#{app.id}/monitor-export?kind=feedback")
    assert response_content_type(feedback_conn, :csv) =~ "text/csv"
    assert feedback_conn.resp_body =~ "when,feedback,question,reply"
    assert feedback_conn.resp_body =~ "rate me"

    usage_conn = get(conn, ~p"/console/apps/#{app.id}/monitor-export?kind=usage")
    assert usage_conn.resp_body =~ "day,messages,input_tokens,output_tokens"
  end

  test "document metadata filters retrieval", %{scope: scope} do
    {:ok, dataset} =
      Flux.RAG.create_dataset(scope, %{
        "name" => "Meta KB",
        "embedding_plugin_id" => "echo",
        "embedding_model" => "echo-embed"
      })

    {:ok, eu_doc} =
      Flux.RAG.add_document(scope, dataset, %{
        name: "eu.md",
        content: "The vacation policy grants 25 days."
      })

    {:ok, us_doc} =
      Flux.RAG.add_document(scope, dataset, %{
        name: "us.md",
        content: "The vacation policy grants 15 days."
      })

    Oban.drain_queue(queue: :ingest)

    {:ok, _} = Flux.RAG.set_document_metadata(scope, eu_doc.id, %{"region" => "EU", "" => "x"})
    {:ok, _} = Flux.RAG.set_document_metadata(scope, us_doc.id, %{"region" => "US"})

    {:ok, all_hits} = Flux.RAG.retrieve(scope, dataset.id, "vacation policy days")
    assert length(all_hits) == 2

    {:ok, eu_hits} =
      Flux.RAG.retrieve(scope, dataset.id, "vacation policy days", metadata: %{"region" => "EU"})

    assert [hit] = eu_hits
    assert hit.content =~ "25 days"
  end

  test "images ingest as vision-described documents", %{scope: scope} do
    # The echo provider doubles as the vision describer once it's the default.
    {:ok, _} = Flux.Providers.set_default_model(scope, "echo", "echo-1")

    assert {:ok, description} =
             Flux.Workflows.describe_image_for_workspace(
               Flux.Accounts.Scope.workspace_id(scope),
               <<137, 80, 78, 71>>,
               "image/png"
             )

    assert description =~ "[1 image(s)]"
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
