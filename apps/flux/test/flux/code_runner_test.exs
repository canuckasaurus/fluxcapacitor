defmodule Flux.CodeRunnerTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Workflows

  @spec_base %{
    language: "python3",
    code: "def main(**kw):\n    return {\"ok\": True}",
    dependencies: [],
    inputs: %{"q" => "hi"},
    timeout_ms: 5_000
  }

  describe "Sandbox backend" do
    setup do
      Application.put_env(:flux, :code_runner_req_options, plug: {Req.Test, Flux.CodeStub})
      Application.put_env(:flux, Flux.CodeRunner.Sandbox, url: "http://coderunner.internal:8194")

      on_exit(fn ->
        Application.delete_env(:flux, :code_runner_req_options)
        Application.delete_env(:flux, Flux.CodeRunner.Sandbox)
      end)
    end

    test "posts the spec and returns result + stdout" do
      parent = self()

      Req.Test.stub(Flux.CodeStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:posted, Jason.decode!(body), conn.request_path})
        Req.Test.json(conn, %{"result" => %{"total" => 7}, "stdout" => "log line\n"})
      end)

      assert {:ok, %{result: %{"total" => 7}, stdout: "log line\n"}} =
               Flux.CodeRunner.Sandbox.run(@spec_base)

      assert_received {:posted, posted, "/run"}
      assert posted["language"] == "python3"
      assert posted["inputs"] == %{"q" => "hi"}
    end

    test "maps runner errors and unset config cleanly" do
      Req.Test.stub(Flux.CodeStub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "SyntaxError: bad"})
      end)

      assert {:error, "SyntaxError: bad"} = Flux.CodeRunner.Sandbox.run(@spec_base)

      Application.put_env(:flux, Flux.CodeRunner.Sandbox, [])
      assert {:error, message} = Flux.CodeRunner.Sandbox.run(@spec_base)
      assert message =~ "CODE_RUNNER_URL"
    end
  end

  describe "Local backend" do
    @describetag :local_python

    test "runs real python, separating result from stdout" do
      Application.put_env(:flux, Flux.CodeRunner.Local, enabled: true)
      on_exit(fn -> Application.delete_env(:flux, Flux.CodeRunner.Local) end)

      spec = %{
        @spec_base
        | code: """
          def main(a: int, b: int) -> dict:
              print("computing")
              return {"sum": a + b}
          """,
          inputs: %{"a" => 2, "b" => 3}
      }

      case Flux.CodeRunner.Local.run(spec) do
        {:ok, %{result: result, stdout: stdout}} ->
          assert result == %{"sum" => 5}
          assert stdout =~ "computing"

        {:error, "no python interpreter" <> _} ->
          :ok
      end
    end

    test "refuses when disabled and refuses non-python" do
      assert {:error, message} = Flux.CodeRunner.Local.run(@spec_base)
      assert message =~ "disabled"

      assert {:error, message} = Flux.CodeRunner.Local.run(%{@spec_base | language: "ruby"})
      assert message =~ "only supports python3"
    end
  end

  describe "code node in a workflow run (Fake backend)" do
    setup do
      account = account_fixture()
      {:ok, {_ws, _}} = Accounts.create_workspace(account, %{name: "Code WS"})
      %{scope: Accounts.scope_for(account)}
    end

    test "code node outputs feed downstream templates", %{scope: scope} do
      {:ok, workflow} = Workflows.create_workflow(scope, %{"name" => "Code Flux"})

      graph = %{
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
            "id" => "code_1",
            "type" => "code",
            "title" => "Code",
            "config" => %{
              "language" => "python3",
              "code" => "def main(q): return {}",
              "dependencies" => [%{"name" => "pandas", "version" => "2.2.*"}],
              "inputs" => [%{"name" => "q", "value" => "{{start.query}}"}]
            }
          },
          %{
            "id" => "end_1",
            "type" => "end",
            "title" => "End",
            "config" => %{
              "outputs" => [
                %{"key" => "lang", "value" => "{{code_1.language}}"},
                %{"key" => "deps", "value" => "{{code_1.deps}}"},
                %{"key" => "logs", "value" => "{{code_1.stdout}}"}
              ]
            }
          }
        ],
        "edges" => [
          %{
            "id" => "e1",
            "source" => "start",
            "source_handle" => "default",
            "target" => "code_1"
          },
          %{"id" => "e2", "source" => "code_1", "source_handle" => "default", "target" => "end_1"}
        ]
      }

      {:ok, workflow} = Workflows.update_draft(scope, workflow, graph)
      {:ok, _run} = Workflows.start_run(scope, workflow, %{"query" => "compute"})

      assert_receive {:run_finished, finished}, 5_000
      assert finished.status == :succeeded
      assert finished.outputs["lang"] == "python3"
      assert finished.outputs["deps"] == "1"
      assert finished.outputs["logs"] =~ "fake-run ok"
    end
  end

  test "the reference platform code fixture imports code nodes without warnings for them" do
    yaml =
      Path.expand("../support/fixtures/dsl", __DIR__)
      |> Path.join("conditional_parallel_code_execution_workflow.yml")
      |> File.read!()

    assert {:ok, parsed} = Flux.Workflows.DSL.parse(yaml)
    refute Enum.any?(parsed.warnings, &(&1 =~ "\"code\""))

    code_nodes = Enum.filter(parsed.graph["nodes"], &(&1["type"] == "code"))
    assert code_nodes != []

    assert Enum.all?(
             code_nodes,
             &(&1["config"]["code"] =~ "def main" or &1["config"]["code"] != "")
           )
  end
end
