defmodule Flux.Plugins.NotionTest do
  use ExUnit.Case, async: false

  alias Flux.Plugins.Notion

  @credentials %{"api_token" => "ntn_test_token"}

  setup do
    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.NotionStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Flux.NotionStub, fun)

  defp page(id, title) do
    %{
      "object" => "page",
      "id" => id,
      "properties" => %{
        "Name" => %{
          "type" => "title",
          "title" => [%{"plain_text" => title}]
        }
      }
    }
  end

  test "list_documents searches pages with the integration token" do
    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/search"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ntn_test_token"]
      assert Plug.Conn.get_req_header(conn, "notion-version") == ["2022-06-28"]

      Req.Test.json(conn, %{
        "results" => [page("page-1", "Handbook"), page("page-2", "Playbook")]
      })
    end)

    assert {:ok, [doc_1, doc_2]} = Notion.list_documents(@credentials)
    assert doc_1.id == "page-1"
    assert doc_1.name == "Handbook"
    assert doc_2.name == "Playbook"
  end

  test "fetch_document flattens rich text across paginated block reads" do
    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/pages/page-1"} ->
          Req.Test.json(conn, page("page-1", "Handbook"))

        {"GET", "/v1/blocks/page-1/children"} ->
          conn = Plug.Conn.fetch_query_params(conn)

          case conn.query_params["start_cursor"] do
            nil ->
              Req.Test.json(conn, %{
                "results" => [
                  %{
                    "type" => "heading_1",
                    "heading_1" => %{"rich_text" => [%{"plain_text" => "Welcome"}]}
                  },
                  %{"type" => "divider", "divider" => %{}}
                ],
                "has_more" => true,
                "next_cursor" => "cursor-2"
              })

            "cursor-2" ->
              Req.Test.json(conn, %{
                "results" => [
                  %{
                    "type" => "paragraph",
                    "paragraph" => %{
                      "rich_text" => [
                        %{"plain_text" => "Be "},
                        %{"plain_text" => "kind."}
                      ]
                    }
                  }
                ],
                "has_more" => false
              })
          end
      end
    end)

    assert {:ok, %{name: "Handbook", content: content}} =
             Notion.fetch_document(@credentials, "page-1")

    assert content == "Welcome\nBe kind."
  end

  test "a rejected token gets a pointed message" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end)

    assert {:error, message} = Notion.list_documents(@credentials)
    assert message =~ "401"
    assert message =~ "integration token"
  end

  test "a missing token never leaves the process" do
    assert {:error, "api_token is required"} = Notion.list_documents(%{})
  end
end
