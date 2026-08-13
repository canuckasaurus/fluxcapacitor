defmodule FluxWeb.Batch32WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.RAG
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch32 Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  describe "Q&A indexing" do
    test "chunks index as generated questions carrying the passage", %{scope: scope} do
      previous = Application.get_env(:flux, :qa_generator)

      Application.put_env(:flux, :qa_generator, fn _chunk ->
        ["How many vacation days do I get?", "Do unused days roll over?"]
      end)

      on_exit(fn -> Application.put_env(:flux, :qa_generator, previous) end)

      {:ok, dataset} =
        RAG.create_dataset(scope, %{
          "name" => "QA KB",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed"
        })

      {:ok, dataset} = RAG.update_dataset(scope, dataset, %{"qa_indexing" => true})

      {:ok, document} =
        RAG.add_document(scope, dataset, %{
          name: "vacation.md",
          content: "Vacation policy: employees receive 25 paid days per year."
        })

      Oban.drain_queue(queue: :ingest)

      segments = RAG.list_segments(scope, document.id)
      assert length(segments) == 2
      assert Enum.any?(segments, &(&1.content =~ "How many vacation days"))
      assert Enum.all?(segments, &(&1.parent_content =~ "25 paid days"))

      # Retrieval hands back the passage (parent promotion), not the question.
      {:ok, [top | _]} = RAG.retrieve(scope, dataset.id, "how many vacation days do I get?")
      assert top.content =~ "25 paid days"
    end
  end

  describe "inbound email trigger" do
    test "a Mailgun-shaped POST starts a run with mail inputs", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Mail Triggered"})

      graph =
        update_in(workflow.graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "llm_1"} = node ->
              node
              |> put_in(["config", "provider_plugin_id"], "echo")
              |> put_in(["config", "model"], "echo-1")

            node ->
              node
          end)
        end)

      {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
      {:ok, _version} = Workflows.publish(scope, workflow)

      {:ok, trigger} = Workflows.create_trigger(scope, workflow, %{"type" => "email"})

      body =
        build_conn()
        |> post(~p"/triggers/email/#{trigger.token}", %{
          "from" => "doc@example.com",
          "subject" => "Flux capacitor query",
          "body-plain" => "Where do I get plutonium?"
        })
        |> json_response(202)

      run = poll_run(scope, body["workflow_run_id"])
      assert run.status == :succeeded
      assert run.inputs["from"] == "doc@example.com"
      assert run.inputs["subject"] == "Flux capacitor query"
      assert run.inputs["query"] == "Where do I get plutonium?"
    end

    test "a webhook token does not answer on the email route", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Hook Only"})
      {:ok, trigger} = Workflows.create_trigger(scope, workflow, %{"type" => "webhook"})

      assert build_conn()
             |> post(~p"/triggers/email/#{trigger.token}", %{"text" => "hi"})
             |> json_response(404)
    end
  end

  describe "conversations CSV download" do
    test "the monitor export includes messages", %{conn: conn, scope: scope, account: account} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "CSV Web App",
          "provider_plugin_id" => "echo",
          "model" => "echo-1"
        })

      conversation = Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Chat.send_message(scope, app, conversation, "csv line please")

      Enum.reduce_while(1..50, nil, fn _try, _acc ->
        case Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true) do
          %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
          done -> {:halt, done}
        end
      end)

      conn = log_in_account(conn, account)
      response = get(conn, ~p"/console/apps/#{app.id}/monitor-export?kind=conversations")

      assert response.status == 200
      assert response.resp_body =~ "csv line please"
      assert response.resp_body =~ "conversation_id"
    end
  end

  describe "canvas frames" do
    test "add, label, and delete a frame on the editor", %{
      conn: conn,
      scope: scope,
      account: account
    } do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Framed Flux"})

      conn = log_in_account(conn, account)
      {:ok, lv, _html} = live(conn, ~p"/console/fluxes/#{workflow.id}")

      html = lv |> element("button[phx-click=add_frame]") |> render_click()
      assert html =~ "frame-f"

      workflow = Workflows.get_workflow(scope, workflow.id)
      assert [frame] = workflow.graph["frames"]
      assert frame["w"] == 320

      lv
      |> element("#frame-#{frame["id"]} input[phx-blur=frame_label]")
      |> render_blur(%{"id" => frame["id"], "value" => "Retrieval stage"})

      workflow = Workflows.get_workflow(scope, workflow.id)
      assert hd(workflow.graph["frames"])["label"] == "Retrieval stage"

      lv
      |> element("#frame-#{frame["id"]} button[phx-click=delete_frame]")
      |> render_click()

      workflow = Workflows.get_workflow(scope, workflow.id)
      assert workflow.graph["frames"] == []
    end
  end

  describe "app icon on the site" do
    test "the emoji shows in the site header when no logo is set", %{conn: conn, scope: scope} do
      {:ok, app} =
        Chat.create_app(scope, %{
          "name" => "Iconic",
          "provider_plugin_id" => "echo",
          "model" => "echo-1",
          "icon" => "🚗"
        })

      {:ok, app} = Chat.enable_site(scope, app)

      {:ok, _lv, html} = live(conn, ~p"/site/#{app.site_token}")
      assert html =~ "🚗"
    end
  end

  defp poll_run(scope, run_id) do
    Enum.reduce_while(1..50, nil, fn _try, acc ->
      case Workflows.get_run(scope, run_id) do
        %{status: :running} -> Process.sleep(100) && {:cont, acc}
        %{} = run -> {:halt, run}
        _error -> {:halt, acc}
      end
    end)
  end
end
