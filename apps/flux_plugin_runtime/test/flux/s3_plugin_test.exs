defmodule Flux.Plugins.S3Test do
  use ExUnit.Case, async: false

  alias Flux.Plugins.S3

  @credentials %{
    "bucket" => "docs-bucket",
    "access_key_id" => "AKIATEST",
    "secret_access_key" => "shhh",
    "endpoint" => "http://minio.example.com:9000",
    "prefix" => "docs/"
  }

  @list_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <ListBucketResult>
    <Name>docs-bucket</Name>
    <Contents><Key>docs/handbook.md</Key><Size>42</Size><ETag>x</ETag><LastModified>2026-08-01T00:00:00Z</LastModified><StorageClass>STANDARD</StorageClass></Contents>
    <Contents><Key>docs/folder/</Key><Size>0</Size><ETag>y</ETag><LastModified>2026-08-01T00:00:00Z</LastModified><StorageClass>STANDARD</StorageClass></Contents>
  </ListBucketResult>
  """

  setup do
    Application.put_env(:flux_plugin_runtime, :s3_req_options, plug: {Req.Test, Flux.S3Stub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :s3_req_options) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Flux.S3Stub, fun)

  test "list_documents lists keys under the prefix, dropping folder markers" do
    stub(fn conn ->
      assert conn.host == "minio.example.com"
      assert [signed] = Plug.Conn.get_req_header(conn, "authorization")
      assert signed =~ "AWS4-HMAC-SHA256"
      assert signed =~ "AKIATEST"

      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.send_resp(200, @list_xml)
    end)

    assert {:ok, [doc]} = S3.list_documents(@credentials)
    assert doc.id == "docs/handbook.md"
    assert doc.name == "handbook.md"
  end

  test "fetch_document returns UTF-8 text and rejects binaries" do
    stub(fn conn ->
      assert conn.request_path =~ "handbook.md"
      Plug.Conn.send_resp(conn, 200, "# Handbook\nBe kind.")
    end)

    assert {:ok, %{name: "handbook.md", content: "# Handbook\nBe kind."}} =
             S3.fetch_document(@credentials, "docs/handbook.md")

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, <<137, 80, 78, 71, 0, 1>>) end)

    assert {:error, message} = S3.fetch_document(@credentials, "docs/logo.png")
    assert message =~ "binary"
  end

  test "denied credentials get a pointed message" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, "<Error/>") end)

    assert {:error, message} = S3.list_documents(@credentials)
    assert message =~ "403"
  end

  test "missing credentials fail before any request" do
    assert {:error, "bucket is required"} = S3.list_documents(%{})

    assert {:error, "access keys are required"} =
             S3.list_documents(%{"bucket" => "b", "access_key_id" => "x"})
  end
end
