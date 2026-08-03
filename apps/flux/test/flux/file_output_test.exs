defmodule Flux.FileOutputTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  defmodule FakePdf do
    def convert_docx(_docx), do: {:ok, "%PDF-1.7 from-docx"}
    def convert_html(html) when is_binary(html), do: {:ok, "%PDF-1.7 from-html"}
  end

  setup do
    account = account_fixture()
    {:ok, {_workspace, _}} = Accounts.create_workspace(account, %{name: "Files WS"})
    scope = Accounts.scope_for(account)

    {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Report Flux"})
    %{scope: scope, workflow: workflow}
  end

  defp graph(format) do
    %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "config" => %{
            "variables" => [%{"name" => "query", "type" => "text", "required" => true}]
          }
        },
        %{
          "id" => "file_1",
          "type" => "file_output",
          "title" => "Report",
          "config" => %{
            "format" => format,
            "content" => "<h1>{{start.query}}</h1>",
            "output_name" => "report"
          }
        },
        %{
          "id" => "end_1",
          "type" => "end",
          "title" => "End",
          "config" => %{
            "outputs" => [
              %{"key" => "url", "value" => "{{file_1.url}}"},
              %{"key" => "name", "value" => "{{file_1.name}}"}
            ]
          }
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "file_1"},
        %{"id" => "e2", "source" => "file_1", "source_handle" => "default", "target" => "end_1"}
      ]
    }
  end

  test "file_output stores a wrapped HTML page as a downloadable run file", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph("html"))
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "88 mph"})
    assert_receive {:run_finished, finished}, 5_000

    assert finished.status == :succeeded
    assert finished.outputs["name"] == "report.html"
    assert "/files/" <> token = finished.outputs["url"]

    {:ok, %{name: "report.html", content_type: "text/html; charset=utf-8", binary: binary}} =
      Workflows.fetch_file_by_token(token)

    assert binary =~ "<!DOCTYPE html>"
    assert binary =~ "<h1>88 mph</h1>"
  end

  test "pdf format converts through the injected converter", %{
    scope: scope,
    workflow: workflow
  } do
    previous = Application.get_env(:flux, Flux.Pdf)
    Application.put_env(:flux, Flux.Pdf, module: FakePdf)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:flux, Flux.Pdf, previous),
        else: Application.delete_env(:flux, Flux.Pdf)
    end)

    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph("pdf"))
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "flux"})
    assert_receive {:run_finished, finished}, 5_000

    assert finished.status == :succeeded
    assert finished.outputs["name"] == "report.pdf"
    assert "/files/" <> token = finished.outputs["url"]

    {:ok, %{content_type: "application/pdf", binary: "%PDF-1.7 from-html"}} =
      Workflows.fetch_file_by_token(token)
  end

  test "pdf format without a converter fails the node honestly", %{
    scope: scope,
    workflow: workflow
  } do
    {:ok, workflow} = Workflows.update_draft(scope, workflow, graph("pdf"))
    {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "flux"})
    assert_receive {:run_finished, finished}, 5_000

    assert finished.status == :failed
    assert finished.error =~ "FLUX_PDF_URL"
  end
end
