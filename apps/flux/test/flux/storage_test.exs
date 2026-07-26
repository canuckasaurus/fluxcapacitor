defmodule Flux.StorageTest do
  use ExUnit.Case, async: false

  alias Flux.Storage

  setup do
    base = Keyword.fetch!(Storage.config(), :local_path)
    on_exit(fn -> File.rm_rf(base) end)
    :ok
  end

  test "put/get/exists?/delete roundtrip through the local adapter" do
    key = "workspaces/#{Ecto.UUID.generate()}/uploads/hello.txt"

    refute Storage.exists?(key)
    assert :ok = Storage.put(key, "hello flux")
    assert Storage.exists?(key)
    assert {:ok, "hello flux"} = Storage.get(key)
    assert :ok = Storage.delete(key)
    refute Storage.exists?(key)
    assert {:error, :not_found} = Storage.get(key)
  end

  test "delete is idempotent" do
    assert :ok = Storage.delete("workspaces/none/missing.bin")
  end

  test "local adapter rejects path traversal" do
    assert_raise ArgumentError, ~r/escapes the storage root/, fn ->
      Storage.put("../../outside.txt", "nope")
    end
  end

  test "local adapter does not support presigned URLs" do
    assert {:error, :unsupported} = Storage.presigned_url("some/key")
  end

  test "s3 adapter builds MinIO-style presigned URLs from config" do
    # Exercise URL signing offline against a fake MinIO endpoint.
    config =
      ExAws.Config.new(:s3,
        access_key_id: "test-access",
        secret_access_key: "test-secret",
        region: "us-east-1",
        scheme: "http://",
        host: "localhost",
        port: 9000
      )

    assert {:ok, url} =
             ExAws.S3.presigned_url(config, :get, "flux-bucket", "workspaces/x/file.bin",
               expires_in: 60,
               virtual_host: false
             )

    assert url =~ "http://localhost:9000/flux-bucket/workspaces/x/file.bin"
    assert url =~ "X-Amz-Signature="
  end
end
