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

  test "rejects binary formats until Tika", %{scope: scope, app: app, workspace: workspace} do
    file = upload!(scope, app, "report.xlsx", <<0, 1, 2, 3>>, "application/vnd.ms-excel")

    assert {:error, message} = Documents.extract(workspace.id, file.id)
    assert message =~ "Tika"
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
