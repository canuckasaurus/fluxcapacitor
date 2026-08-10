defmodule FluxWeb.Batch26WebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Workflows

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Batch26 Web WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Claude App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1",
        "system_prompt" => "You echo."
      })

    {:ok, _token, app_raw} = Chat.create_api_token(scope, app)

    app_conn =
      conn
      |> put_req_header("authorization", "Bearer " <> app_raw)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, app_conn: app_conn, scope: scope, workspace: workspace, app: app}
  end

  describe "Anthropic-compatible /v1/messages" do
    test "blocking replies in Anthropic shape with a system prompt", %{app_conn: app_conn} do
      response =
        app_conn
        |> post(
          ~p"/v1/messages",
          Jason.encode!(%{
            "model" => "ignored",
            "max_tokens" => 256,
            "system" => "Stay brief.",
            "messages" => [
              %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello claude"}]}
            ]
          })
        )
        |> json_response(200)

      assert response["type"] == "message"
      assert response["role"] == "assistant"
      assert String.starts_with?(response["id"], "msg_")
      assert [%{"type" => "text", "text" => text}] = response["content"]
      assert text =~ "You said: hello claude"
      assert response["stop_reason"] == "end_turn"
      assert response["usage"]["output_tokens"] == 12
    end

    test "streaming follows the Anthropic event sequence", %{app_conn: app_conn} do
      conn =
        post(
          app_conn,
          ~p"/v1/messages",
          Jason.encode!(%{
            "stream" => true,
            "messages" => [%{"role" => "user", "content" => "stream me"}]
          })
        )

      body = response(conn, 200)
      assert body =~ "event: message_start"
      assert body =~ "event: content_block_delta"
      assert body =~ ~s("type":"text_delta")
      assert body =~ "event: message_stop"
    end

    test "empty or malformed messages 400", %{app_conn: app_conn} do
      response =
        app_conn
        |> post(~p"/v1/messages", Jason.encode!(%{"messages" => []}))
        |> json_response(400)

      assert response["error"]["type"] == "invalid_request_error"
    end
  end

  describe "OpenAI-compat audio" do
    test "transcriptions accept multipart audio", %{conn: conn, scope: scope, app: app} do
      {:ok, _} = Flux.Providers.set_default_model(scope, "echo", "echo-1")
      {:ok, _token, raw} = Chat.create_api_token(scope, app)

      upload = %Plug.Upload{
        path: write_temp!("fake-audio-bytes"),
        filename: "memo.mp3",
        content_type: "audio/mpeg"
      }

      response =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/v1/audio/transcriptions", %{"file" => upload})
        |> json_response(200)

      assert response["text"] =~ "transcribed 16 bytes"
    end

    test "speech answers audio bytes", %{app_conn: app_conn, scope: scope} do
      {:ok, _} = Flux.Providers.set_default_model(scope, "echo", "echo-1")

      conn =
        post(app_conn, ~p"/v1/audio/speech", Jason.encode!(%{"input" => "say this aloud"}))

      assert response(conn, 200) =~ "FAKE-MP3:"
      assert get_resp_header(conn, "content-type") |> hd() =~ "audio/mpeg"
    end

    test "no default provider 400s honestly", %{app_conn: app_conn} do
      response =
        app_conn
        |> post(~p"/v1/audio/speech", Jason.encode!(%{"input" => "anything"}))
        |> json_response(400)

      assert response["error"]["message"] =~ "cannot synthesize"
    end
  end

  describe "run API" do
    setup %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Run API Flux"})

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
      {:ok, _token, raw} = Workflows.create_api_token(scope, workflow)

      %{workflow: workflow, flux_raw: raw}
    end

    test "show returns status and an optional trace; stop 409s when finished", %{
      conn: conn,
      flux_raw: raw
    } do
      flux_conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")

      started =
        flux_conn
        |> post(
          ~p"/v1/workflows/run",
          Jason.encode!(%{"inputs" => %{"query" => "trace me"}, "response_mode" => "blocking"})
        )
        |> json_response(200)

      run_id = started["workflow_run_id"]

      body = flux_conn |> get(~p"/v1/workflows/runs/#{run_id}") |> json_response(200)
      assert body["status"] == "succeeded"
      refute Map.has_key?(body, "node_executions")

      traced =
        flux_conn |> get(~p"/v1/workflows/runs/#{run_id}?trace=true") |> json_response(200)

      assert is_list(traced["node_executions"])
      assert traced["node_executions"] != []

      stopped = flux_conn |> post(~p"/v1/workflows/runs/#{run_id}/stop") |> json_response(409)
      assert stopped["code"] == "not_running"

      missing =
        flux_conn
        |> get(~p"/v1/workflows/runs/#{Ecto.UUID.generate()}")
        |> json_response(404)

      assert missing["code"] == "not_found"
    end

    test "app tokens are refused", %{app_conn: app_conn} do
      response =
        app_conn
        |> get(~p"/v1/workflows/runs/#{Ecto.UUID.generate()}")
        |> json_response(403)

      assert response["code"] == "invalid_token_kind"
    end
  end

  describe "dataset export/import" do
    test "the archive round-trips into a new dataset", %{scope: scope} do
      {:ok, dataset} =
        Flux.RAG.create_dataset(scope, %{
          "name" => "Portable DS",
          "embedding_plugin_id" => "echo",
          "embedding_model" => "echo-embed",
          "parent_child" => true
        })

      {:ok, doc} =
        Flux.RAG.add_document(scope, dataset, %{name: "a.md", content: "portable text"})

      Oban.drain_queue(queue: :ingest)
      {:ok, _} = Flux.RAG.set_document_tags(scope, doc.id, ["legal"])

      {:ok, _case} =
        Flux.RAG.add_retrieval_case(scope, dataset, %{
          "question" => "what text?",
          "expected" => "portable text"
        })

      {:ok, archive} = Flux.RAG.export_dataset(scope, dataset.id)
      assert archive["format"] == "flux-dataset/v1"
      assert archive["settings"]["parent_child"] == true
      assert [%{"name" => "a.md", "tags" => ["legal"]}] = archive["documents"]

      # Round-trip through JSON like the download/upload path does.
      decoded = archive |> Jason.encode!() |> Jason.decode!()
      {:ok, imported, counts} = Flux.RAG.import_dataset(scope, decoded)

      assert imported.parent_child == true
      assert counts == %{documents: 1, retrieval_cases: 1, url_sources: 0}

      Oban.drain_queue(queue: :ingest)
      [imported_doc] = Flux.RAG.list_documents(scope, imported.id)
      assert imported_doc.status == :ready
      assert imported_doc.tags == ["legal"]

      assert {:error, :unrecognized_archive} =
               Flux.RAG.import_dataset(scope, %{"format" => "something-else"})
    end
  end

  defp write_temp!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "batch26-audio-#{System.unique_integer([:positive])}.mp3"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
