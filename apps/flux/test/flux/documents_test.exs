defmodule Flux.DocumentsTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Documents

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Docs WS"})
    scope = Accounts.scope_for(account)

    {:ok, app} =
      Chat.create_app(scope, %{
        "name" => "Docs App",
        "provider_plugin_id" => "echo",
        "model" => "echo-1"
      })

    %{scope: scope, app: app, workspace: workspace}
  end

  defp upload!(scope, app, filename, content, content_type) do
    path = Path.join(System.tmp_dir!(), "doc-#{System.unique_integer([:positive])}")
    File.write!(path, content)

    {:ok, file} =
      Chat.create_upload(scope, app, %{
        path: path,
        filename: filename,
        content_type: content_type
      })

    file
  end

  test "extracts plain text", %{scope: scope, app: app, workspace: workspace} do
    file = upload!(scope, app, "notes.txt", "hello docs", "text/plain")

    assert {:ok, %{text: "hello docs", name: "notes.txt"}} =
             Documents.extract(workspace.id, file.id)
  end

  test "strips HTML", %{scope: scope, app: app, workspace: workspace} do
    html = "<html><body><h1>Title</h1><p>Body text.</p></body></html>"
    file = upload!(scope, app, "page.html", html, "text/html")

    assert {:ok, %{text: text}} = Documents.extract(workspace.id, file.id)
    assert text =~ "Title"
    assert text =~ "Body text."
    refute text =~ "<p>"
  end

  test "rejects binary formats when no Tika is configured", %{
    scope: scope,
    app: app,
    workspace: workspace
  } do
    file = upload!(scope, app, "report.xlsx", <<0, 1, 2, 3>>, "application/vnd.ms-excel")

    assert {:error, message} = Documents.extract(workspace.id, file.id)
    assert message =~ "FLUX_TIKA_URL"
  end

  defmodule FakeTika do
    def extract(binary, content_type) do
      send(self(), {:tika_called, byte_size(binary), content_type})
      {:ok, "Quarterly revenue: 1.21 GW"}
    end
  end

  test "routes office formats through Tika when configured", %{
    scope: scope,
    app: app,
    workspace: workspace
  } do
    Application.put_env(:flux, Flux.Tika, module: FakeTika)
    on_exit(fn -> Application.delete_env(:flux, Flux.Tika) end)

    xlsx_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    file = upload!(scope, app, "report.xlsx", <<80, 75, 3, 4>>, xlsx_type)

    assert {:ok, %{text: "Quarterly revenue: 1.21 GW"}} =
             Documents.extract(workspace.id, file.id)

    assert_received {:tika_called, 4, ^xlsx_type}
  end

  test "native formats never reach Tika", %{scope: scope, app: app, workspace: workspace} do
    Application.put_env(:flux, Flux.Tika, module: FakeTika)
    on_exit(fn -> Application.delete_env(:flux, Flux.Tika) end)

    file = upload!(scope, app, "notes.txt", "native path", "text/plain")
    assert {:ok, %{text: "native path"}} = Documents.extract(workspace.id, file.id)
    refute_received {:tika_called, _size, _type}
  end

  test "reads Word documents natively", %{scope: scope, app: app, workspace: workspace} do
    document = """
    <?xml version="1.0"?>
    <w:document xmlns:w="wns"><w:body>\
    <w:p><w:r><w:t>First paragraph &amp; more.</w:t></w:r></w:p>\
    <w:p><w:r><w:t xml:space="preserve">Second </w:t></w:r><w:r><w:t>paragraph.</w:t></w:r></w:p>\
    </w:body></w:document>
    """

    {:ok, {_name, binary}} =
      :zip.create(~c"d.docx", [{~c"word/document.xml", document}], [:memory])

    file =
      upload!(
        scope,
        app,
        "letter.docx",
        binary,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      )

    assert {:ok, %{text: text}} = Documents.extract(workspace.id, file.id)
    assert text =~ "First paragraph & more."
    assert text =~ "Second paragraph."

    # Corrupt zips fail with a clear message, not a crash.
    bad = upload!(scope, app, "broken.docx", <<0, 1, 2>>, nil)
    assert {:error, message} = Documents.extract(workspace.id, bad.id)
    assert message =~ "Word"
  end

  test "workspace-checks the file id", %{scope: scope, app: app} do
    file = upload!(scope, app, "notes.txt", "secret", "text/plain")

    other = account_fixture()
    {:ok, {other_workspace, _}} = Accounts.create_workspace(other, %{name: "Other Docs WS"})

    assert {:error, "file not found"} = Documents.extract(other_workspace.id, file.id)
    assert {:error, "not a file id: \"nope\""} = Documents.extract(other_workspace.id, "nope")
  end
end
