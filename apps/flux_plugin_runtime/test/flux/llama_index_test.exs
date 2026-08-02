defmodule Flux.Plugins.LlamaIndexTest do
  use ExUnit.Case, async: false

  alias Flux.Plugins.LlamaIndex

  @credentials %{
    "base_url" => "https://llama.example.com",
    "api_key" => "llx-test-key",
    "pipeline_id" => "pipe-default"
  }

  setup do
    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.LlamaStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Flux.LlamaStub, fun)

  test "retrieve hits the pipeline endpoint with auth and joins chunks" do
    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/pipelines/pipe-42/retrieve"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer llx-test-key"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["query"] == "indemnification clauses"
      assert payload["dense_similarity_top_k"] == 3

      Req.Test.json(conn, %{
        "retrieval_nodes" => [
          %{"node" => %{"text" => "Clause A"}, "score" => 0.91},
          %{"node" => %{"text" => "Clause B"}, "score" => 0.77}
        ]
      })
    end)

    assert {:ok, %{text: text, data: data}} =
             LlamaIndex.invoke(@credentials, "retrieve", %{
               "query" => "indemnification clauses",
               "pipeline_id" => "pipe-42",
               "top_k" => 3
             })

    assert text == "Clause A\n\n---\n\nClause B"
    assert data["count"] == 2
    assert [%{"score" => 0.91} | _rest] = data["nodes"]
  end

  test "retrieve falls back to the credential default pipeline" do
    stub(fn conn ->
      assert conn.request_path == "/api/v1/pipelines/pipe-default/retrieve"
      Req.Test.json(conn, %{"retrieval_nodes" => []})
    end)

    assert {:ok, %{data: %{"count" => 0}}} =
             LlamaIndex.invoke(@credentials, "retrieve", %{"query" => "anything"})
  end

  test "retrieve without any pipeline id is an honest error" do
    credentials = Map.delete(@credentials, "pipeline_id")

    assert {:error, message} = LlamaIndex.invoke(credentials, "retrieve", %{"query" => "q"})
    assert message =~ "pipeline id"
  end

  test "run_workflow posts to the llama_deploy task route" do
    stub(fn conn ->
      assert conn.request_path == "/deployments/contract-review/tasks/run"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"input" => "review this"}
      Req.Test.json(conn, %{"result" => "Two issues found."})
    end)

    assert {:ok, %{text: "Two issues found.", data: %{"result" => _result}}} =
             LlamaIndex.invoke(@credentials, "run_workflow", %{
               "deployment" => "contract-review",
               "input" => "review this"
             })
  end

  test "list_pipelines returns ids and names" do
    stub(fn conn ->
      assert conn.request_path == "/api/v1/pipelines"

      Req.Test.json(conn, [
        %{"id" => "pipe-1", "name" => "Contracts"},
        %{"id" => "pipe-2", "name" => "Policies"}
      ])
    end)

    assert {:ok, %{text: text, data: %{"pipelines" => pipelines}}} =
             LlamaIndex.invoke(@credentials, "list_pipelines", %{})

    assert text =~ "Contracts (pipe-1)"
    assert length(pipelines) == 2
  end

  test "401 surfaces as a key problem" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end)

    assert {:error, message} = LlamaIndex.invoke(@credentials, "list_pipelines", %{})
    assert message =~ "API key"
  end

  test "credential validation falls back to the deployments listing" do
    stub(fn conn ->
      case conn.request_path do
        "/api/v1/pipelines" -> Plug.Conn.send_resp(conn, 404, "{}")
        "/deployments" -> Req.Test.json(conn, [%{"name" => "contract-review"}])
      end
    end)

    assert :ok = LlamaIndex.validate_credentials(@credentials)
  end

  test "the manifest registers as a tool plugin" do
    assert %{id: "llama_index", category: :tool} = LlamaIndex.manifest()
    assert Enum.any?(Flux.PluginRuntime.list_tool_plugins(), &(&1.id == "llama_index"))

    operation_ids = Enum.map(LlamaIndex.operations(%{}), & &1.id)
    assert operation_ids == ["retrieve", "run_workflow", "list_pipelines"]
  end
end
