defmodule Flux.Plugins.LabelStudioTest do
  use ExUnit.Case, async: false

  alias Flux.Plugins.LabelStudio

  @credentials %{
    "base_url" => "https://labels.example.com",
    "api_token" => "ls-secret-token",
    "project_id" => "7"
  }

  setup do
    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.LabelStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Flux.LabelStub, fun)

  defp labeled_tasks do
    [
      %{
        "id" => 11,
        "data" => %{"text" => "Refund my order"},
        "annotations" => [%{"result" => [%{"value" => %{"choices" => ["complaint"]}}]}]
      },
      %{
        "id" => 12,
        "data" => %{"question" => "hours?", "answer" => "9-5"},
        "annotations" => [%{"result" => [%{"value" => %{"choices" => ["ok"]}}]}]
      }
    ]
  end

  test "list_projects uses token auth" do
    stub(fn conn ->
      assert conn.request_path == "/api/projects"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Token ls-secret-token"]

      Req.Test.json(conn, %{
        "results" => [%{"id" => 7, "title" => "Complaints", "task_number" => 40}]
      })
    end)

    assert {:ok, %{text: text, data: data}} =
             LabelStudio.invoke(@credentials, "list_projects", %{})

    assert text =~ "7: Complaints (40 tasks)"
    assert data["count"] == 1
  end

  test "create_tasks wraps strings and imports into the default project" do
    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/projects/7/import"

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == [
               %{"data" => %{"text" => "label me"}},
               %{"data" => %{"question" => "q", "answer" => "a"}}
             ]

      Req.Test.json(conn, %{"task_count" => 2})
    end)

    assert {:ok, %{data: %{"task_count" => 2}}} =
             LabelStudio.invoke(@credentials, "create_tasks", %{
               "items" => ["label me", %{"question" => "q", "answer" => "a"}]
             })
  end

  test "export_annotations returns labeled tasks only" do
    stub(fn conn ->
      assert conn.request_path == "/api/projects/7/export"
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["download_all_tasks"] == "false"
      Req.Test.json(conn, labeled_tasks())
    end)

    assert {:ok, %{data: %{"count" => 2}}} =
             LabelStudio.invoke(@credentials, "export_annotations", %{})
  end

  test "datasource lists and fetches labeled tasks" do
    stub(fn conn -> Req.Test.json(conn, labeled_tasks()) end)

    assert {:ok, [doc_1, doc_2]} = LabelStudio.list_documents(@credentials)
    assert doc_1.id == "11"
    assert doc_1.name =~ "Refund my order"
    assert doc_2.id == "12"

    assert {:ok, %{content: content}} = LabelStudio.fetch_document(@credentials, "11")
    decoded = Jason.decode!(content)
    assert decoded["data"]["text"] == "Refund my order"
    assert [%{"result" => [_labeled]}] = decoded["annotations"]
  end

  test "auth failures and missing project ids get pointed messages" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end)
    assert {:error, message} = LabelStudio.invoke(@credentials, "list_projects", %{})
    assert message =~ "API token"

    assert {:error, message} =
             LabelStudio.invoke(Map.delete(@credentials, "project_id"), "export_annotations", %{})

    assert message =~ "no project id"

    assert {:error, "items is empty — nothing to label"} =
             LabelStudio.invoke(@credentials, "create_tasks", %{"items" => []})
  end
end
