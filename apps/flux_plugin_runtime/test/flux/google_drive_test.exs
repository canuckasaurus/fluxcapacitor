defmodule Flux.Plugins.GoogleDriveTest do
  use ExUnit.Case, async: false

  alias Flux.Plugins.GoogleDrive

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})

    pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    account =
      Jason.encode!(%{
        "type" => "service_account",
        "client_email" => "flux@project.iam.gserviceaccount.com",
        "private_key" => pem,
        "token_uri" => "https://oauth2.googleapis.com/token"
      })

    %{credentials: %{"service_account_json" => account, "folder_id" => "folder-1"}, key: key}
  end

  setup do
    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.DriveStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Flux.DriveStub, fun)

  defp with_token(fun, key) do
    fn conn ->
      case conn.host do
        "oauth2.googleapis.com" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)
          assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"

          # The JWT must verify against the service account's own key.
          [header, claims, signature] = String.split(params["assertion"], ".")

          assert :public_key.verify(
                   header <> "." <> claims,
                   :sha256,
                   Base.url_decode64!(signature, padding: false),
                   key
                 )

          decoded = claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
          assert decoded["iss"] == "flux@project.iam.gserviceaccount.com"
          assert decoded["scope"] =~ "drive.readonly"

          Req.Test.json(conn, %{"access_token" => "ya29.test-token"})

        "www.googleapis.com" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ya29.test-token"]
          fun.(conn)
      end
    end
  end

  test "list_documents mints a real RS256 assertion and lists the folder", %{
    credentials: credentials,
    key: key
  } do
    stub(
      with_token(
        fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params["q"] =~ "'folder-1' in parents"

          Req.Test.json(conn, %{
            "files" => [
              %{
                "id" => "doc-1",
                "name" => "Handbook",
                "mimeType" => "application/vnd.google-apps.document"
              },
              %{"id" => "img-1", "name" => "logo.png", "mimeType" => "image/png"}
            ]
          })
        end,
        key
      )
    )

    assert {:ok, [doc]} = GoogleDrive.list_documents(credentials)
    assert doc.id == "doc-1"
    assert doc.name == "Handbook"
  end

  test "fetch_document exports Google Docs as plain text", %{
    credentials: credentials,
    key: key
  } do
    stub(
      with_token(
        fn conn ->
          cond do
            conn.request_path == "/drive/v3/files/doc-1" ->
              Req.Test.json(conn, %{
                "id" => "doc-1",
                "name" => "Handbook",
                "mimeType" => "application/vnd.google-apps.document"
              })

            conn.request_path == "/drive/v3/files/doc-1/export" ->
              conn = Plug.Conn.fetch_query_params(conn)
              assert conn.query_params["mimeType"] == "text/plain"
              Plug.Conn.send_resp(conn, 200, "Be kind. Ship weekly.")
          end
        end,
        key
      )
    )

    assert {:ok, %{name: "Handbook", content: "Be kind. Ship weekly."}} =
             GoogleDrive.fetch_document(credentials, "doc-1")
  end

  test "a malformed key file fails before any network call" do
    assert {:error, message} =
             GoogleDrive.list_documents(%{"service_account_json" => ~s({"nope": true})})

    assert message =~ "full JSON key file"

    assert {:error, "service_account_json is required"} = GoogleDrive.list_documents(%{})
  end
end
