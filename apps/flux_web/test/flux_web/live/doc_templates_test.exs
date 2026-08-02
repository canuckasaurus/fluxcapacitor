defmodule FluxWeb.DocTemplatesTest do
  use FluxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.DocTemplates

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Tpl WS"})
    scope = Accounts.scope_for(account)
    %{conn: log_in_account(conn, account), scope: scope}
  end

  test "CRUD with jinja validation at save time", %{scope: scope} do
    assert {:ok, template} =
             DocTemplates.create(scope, %{
               "name" => "Offer letter",
               "description" => "HR boilerplate",
               "content" => "Dear {{ start.name | capitalize }}, welcome!"
             })

    # Broken jinja is rejected with the renderer's message.
    assert {:error, changeset} =
             DocTemplates.create(scope, %{"name" => "Broken", "content" => "{% if x %}oops"})

    assert {"invalid template: " <> _reason, _opts} = changeset.errors[:content]

    {:ok, updated} = DocTemplates.update(scope, template, %{"content" => "Hi {{ start.name }}!"})
    assert updated.content == "Hi {{ start.name }}!"

    assert [%{name: "Offer letter"}] = DocTemplates.list(scope)
    {:ok, _deleted} = DocTemplates.delete(scope, template.id)
    assert DocTemplates.list(scope) == []
  end

  test "a template node renders a saved doc template in a real run", %{scope: scope} do
    {:ok, template} =
      DocTemplates.create(scope, %{
        "name" => "Greeting",
        "content" =>
          "{% if start.query == 'vip' %}Welcome back, honored guest!" <>
            "{% else %}Hello {{ start.query | capitalize }}.{% endif %}"
      })

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Doc Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "doc",
          "type" => "template",
          "title" => "Doc",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{"template_id" => template.id}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "doc"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "marty"})
    assert_receive {:run_finished, finished}, 5_000
    assert finished.outputs["output"] == "Hello Marty."

    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "vip"})
    assert_receive {:run_finished, vip_run}, 5_000
    assert vip_run.outputs["output"] == "Welcome back, honored guest!"

    # A deleted template fails the node with a clear error.
    {:ok, _} = DocTemplates.delete(scope, template.id)
    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "x"})
    assert_receive {:run_finished, failed}, 5_000
    assert failed.status == :failed
    assert failed.error =~ "doc template not found"
  end

  test "the library page creates with live preview", %{conn: conn, scope: scope} do
    {:ok, lv, html} = live(conn, ~p"/console/templates")
    assert html =~ "Doc templates"

    lv |> element("button", "New text template") |> render_click()

    # Typing re-renders the preview against the sample context.
    html =
      lv
      |> form("#doc-template-form", %{
        "name" => "Echo card",
        "description" => "",
        "content" => "Q: {{ start.query | upper }}",
        "context" => ~s({"start": {"query": "hello"}})
      })
      |> render_change()

    assert html =~ "Q: HELLO"

    # Bad jinja shows the error inline in the preview.
    html =
      lv
      |> form("#doc-template-form", %{"content" => "{% for x %}"})
      |> render_change()

    assert html =~ "unknown tag"

    lv
    |> form("#doc-template-form", %{
      "name" => "Echo card",
      "content" => "Q: {{ start.query | upper }}"
    })
    |> render_submit()

    assert [%{name: "Echo card"}] = DocTemplates.list(scope)
  end

  # A minimal in-memory Word file — same shape the engine tests use.
  defp docx_binary(body_text) do
    document = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:body><w:p><w:r><w:t xml:space="preserve">#{body_text}</w:t></w:r></w:p></w:body>
    </w:document>
    """

    types = ~s(<?xml version="1.0"?><Types xmlns="ct"/>)

    {:ok, {_name, binary}} =
      :zip.create(
        ~c"t.docx",
        [{~c"[Content_Types].xml", types}, {~c"word/document.xml", document}],
        [:memory]
      )

    binary
  end

  test "docx templates upload with validation and variable discovery", %{scope: scope} do
    assert {:ok, template} =
             DocTemplates.create_docx(scope, %{
               binary: docx_binary("Dear {{ client.name }}, re: {{ matter }}"),
               name: "Engagement letter",
               description: "Standard engagement"
             })

    assert template.kind == "docx"
    assert template.variables == ["client", "matter"]

    # Broken Jinja never reaches storage.
    assert {:error, message} =
             DocTemplates.create_docx(scope, %{
               binary: docx_binary("{% if x %}never closed"),
               name: "Broken"
             })

    assert message =~ "endif"

    # Not-a-docx is refused outright.
    assert {:error, message} =
             DocTemplates.create_docx(scope, %{binary: "plain text", name: "Nope"})

    assert message =~ ".docx"

    # Text-node capability refuses a Word template (and vice versa).
    workspace_id = scope.workspace.id
    assert {:error, msg} = DocTemplates.fetch_content(workspace_id, template.id)
    assert msg =~ "document node"

    assert {:ok, %{binary: binary, name: "Engagement letter"}} =
             DocTemplates.fetch_docx(workspace_id, template.id)

    assert is_binary(binary)

    # Deleting removes the stored file too.
    key = template.file_key
    assert {:ok, _binary} = Flux.Storage.get(key)
    {:ok, _} = DocTemplates.delete(scope, template.id)
    assert {:error, _reason} = Flux.Storage.get(key)
  end

  test "docx download and test render through the controller", %{conn: conn, scope: scope} do
    {:ok, template} =
      DocTemplates.create_docx(scope, %{
        binary: docx_binary("Hello {{ who }}!"),
        name: "Card"
      })

    conn2 = get(conn, ~p"/console/templates/#{template.id}/file")
    assert conn2.status == 200
    assert get_resp_header(conn2, "content-disposition") |> hd() =~ "Card.docx"

    conn3 =
      post(conn, ~p"/console/templates/#{template.id}/test-render", %{
        "context" => ~s({"who": "Doc Brown"})
      })

    assert conn3.status == 200
    {:ok, entries} = :zip.unzip(conn3.resp_body, [:memory])
    {_name, xml} = List.keyfind(entries, ~c"word/document.xml", 0)
    assert to_string(xml) =~ "Hello Doc Brown!"

    # The library page shows the Word badge and discovered variables.
    {:ok, _lv, html} = live(conn, ~p"/console/templates")
    assert html =~ "Word"
    assert html =~ "who"
  end

  test "a document node fills a Word template in a real run", %{conn: conn, scope: scope} do
    {:ok, template} =
      DocTemplates.create_docx(scope, %{
        binary: docx_binary("This letter concerns {{ start.matter }}."),
        name: "Letter"
      })

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Letter Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [%{"name" => "matter", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "doc",
          "type" => "document",
          "title" => "Fill letter",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{
            "template_id" => template.id,
            "output_name" => "Letter - {{start.matter}}"
          }
        },
        %{
          "id" => "end",
          "type" => "end",
          "title" => "End",
          "position" => %{"x" => 600, "y" => 0},
          "config" => %{
            "outputs" => [
              %{"key" => "url", "value" => "{{doc.url}}"},
              %{"key" => "name", "value" => "{{doc.name}}"}
            ]
          }
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "doc"},
        %{"id" => "e2", "source" => "doc", "source_handle" => "default", "target" => "end"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)
    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"matter" => "the estate"})
    assert_receive {:run_finished, finished}, 5_000

    assert finished.status == :succeeded
    assert finished.outputs["name"] == "Letter - the estate.docx"
    assert "/files/file_" <> _token = finished.outputs["url"]

    # The tokenized URL serves the filled document with no session.
    download = build_conn() |> get(finished.outputs["url"])
    assert download.status == 200
    {:ok, entries} = :zip.unzip(download.resp_body, [:memory])
    {_name, xml} = List.keyfind(entries, ~c"word/document.xml", 0)
    assert to_string(xml) =~ "This letter concerns the estate."

    # A bogus token 404s.
    assert build_conn() |> get(~p"/files/file_bogus") |> Map.fetch!(:status) == 404
    _ = conn
  end

  defmodule FakePdf do
    def convert_docx(_docx), do: {:ok, "%PDF-1.7 fake"}
  end

  test "pdf output converts through the configured converter", %{scope: scope} do
    {:ok, template} =
      DocTemplates.create_docx(scope, %{
        binary: docx_binary("Re: {{ start.matter }}"),
        name: "Memo"
      })

    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "PDF Flux"})

    graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [%{"name" => "matter", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "doc",
          "type" => "document",
          "title" => "Fill",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{"template_id" => template.id, "output_format" => "pdf"}
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "doc"}
      ]
    }

    {:ok, workflow} = Flux.Workflows.update_draft(scope, workflow, graph)

    # No converter configured: the node fails loudly.
    original = Application.get_env(:flux, Flux.Pdf)
    on_exit(fn -> restore_pdf_config(original) end)
    Application.delete_env(:flux, Flux.Pdf)

    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"matter" => "x"})
    assert_receive {:run_finished, failed}, 5_000
    assert failed.status == :failed
    assert failed.error =~ "FLUX_PDF_URL"

    # With a converter, the output is the converted PDF.
    Application.put_env(:flux, Flux.Pdf, module: FakePdf)

    {:ok, _run} = Flux.Workflows.start_run(scope, workflow, %{"matter" => "y"})
    assert_receive {:run_finished, finished}, 5_000
    assert finished.status == :succeeded
    assert finished.outputs["name"] == "Memo.pdf"

    download = build_conn() |> get(finished.outputs["url"])
    assert download.resp_body == "%PDF-1.7 fake"
    assert get_resp_header(download, "content-type") |> hd() =~ "application/pdf"
  end

  defp restore_pdf_config(nil), do: Application.delete_env(:flux, Flux.Pdf)
  defp restore_pdf_config(value), do: Application.put_env(:flux, Flux.Pdf, value)

  test "one click scaffolds an interview flux from a Word template", %{
    conn: conn,
    scope: scope
  } do
    {:ok, template} =
      DocTemplates.create_docx(scope, %{
        binary: docx_binary("{{ client_name }} vs {{ opposing_party }}"),
        name: "Complaint"
      })

    {:ok, lv, _html} = live(conn, ~p"/console/templates")

    lv
    |> element("button[phx-value-template-id='#{template.id}']", "Create interview flux")
    |> render_click()

    assert [workflow] =
             Enum.filter(
               Flux.Workflows.list_workflows(scope),
               &(&1.name == "Complaint interview")
             )

    workflow = Flux.Workflows.get_workflow(scope, workflow.id)
    start = Enum.find(workflow.graph["nodes"], &(&1["id"] == "start"))

    assert [
             %{"name" => "client_name", "label" => "Client name", "required" => true},
             %{"name" => "opposing_party", "label" => "Opposing party", "required" => true}
           ] = start["config"]["variables"]

    # The scaffold runs end-to-end as generated.
    {:ok, _run} =
      Flux.Workflows.start_run(scope, workflow, %{
        "client_name" => "McFly",
        "opposing_party" => "Tannen"
      })

    assert_receive {:run_finished, finished}, 5_000
    assert finished.status == :succeeded
    assert "/files/file_" <> _token = finished.outputs["document_url"]
    assert finished.outputs["document_name"] == "Complaint.docx"
  end
end
