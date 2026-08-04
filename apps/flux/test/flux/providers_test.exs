defmodule Flux.ProvidersTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Providers

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Prov WS"})
    %{scope: Accounts.scope_for(account), workspace: workspace}
  end

  test "upsert validates with the plugin and stores ciphertext", %{
    scope: scope,
    workspace: workspace
  } do
    assert {:error, {:invalid_credentials, _}} =
             Providers.upsert_credential(scope, "openai", %{"api_key" => "wrong"})

    assert {:ok, credential} =
             Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})

    assert credential.validated_at
    refute credential.encrypted_config =~ "sk-valid"

    assert {:ok, %{"api_key" => "sk-valid"}} = Providers.fetch_config(workspace.id, "openai")
  end

  test "upsert replaces existing credentials", %{scope: scope, workspace: workspace} do
    {:ok, _} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})
    {:ok, _} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})

    assert length(Providers.list_credentials(scope)) == 1
    assert {:ok, %{"api_key" => "sk-valid"}} = Providers.fetch_config(workspace.id, "openai")
  end

  test "named credentials coexist and the default one resolves", %{
    scope: scope,
    workspace: workspace
  } do
    # FakeRuntime treats any sk-valid key as valid; store distinct configs.
    {:ok, first} =
      Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid", "tag" => "one"})

    {:ok, second} =
      Providers.upsert_credential(
        scope,
        "openai",
        %{"api_key" => "sk-valid", "tag" => "two"},
        "rotation"
      )

    assert first.name == "default"
    assert second.name == "rotation"
    assert length(Providers.list_credentials(scope)) == 2

    # The first credential became the default and resolves.
    assert {:ok, %{"tag" => "one"}} = Providers.fetch_config(workspace.id, "openai")

    # Promote the rotation key: resolution flips without touching nodes.
    :ok = Providers.set_default_credential(scope, second.id)
    assert {:ok, %{"tag" => "two"}} = Providers.fetch_config(workspace.id, "openai")

    # Deleting the default promotes the survivor.
    {:ok, _} = Providers.delete_credential(scope, second.id)
    assert {:ok, %{"tag" => "one"}} = Providers.fetch_config(workspace.id, "openai")

    [survivor] = Providers.list_credentials(scope)
    assert survivor.is_default
  end

  test "configuring openai unlocks its models", %{scope: scope} do
    refute Enum.any?(Providers.available_models(scope), &(&1.plugin_id == "openai"))

    {:ok, _} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})

    assert Enum.any?(
             Providers.available_models(scope),
             &(&1.plugin_id == "openai" and &1.model.name == "gpt-4o")
           )
  end

  test "credential management requires plugin_model_config", %{scope: scope} do
    member = account_fixture()
    workspace_id = Flux.Accounts.Scope.workspace_id(scope)

    {:ok, _} =
      %Flux.Accounts.Membership{}
      |> Flux.Accounts.Membership.changeset(%{
        workspace_id: workspace_id,
        account_id: member.id,
        role: :normal
      })
      |> Repo.insert()

    {:ok, _} = Accounts.switch_workspace(member, workspace_id)
    member_scope = Accounts.scope_for(member)

    assert {:error, :unauthorized} =
             Providers.upsert_credential(member_scope, "openai", %{"api_key" => "sk-valid"})
  end

  test "delete removes credentials", %{scope: scope, workspace: workspace} do
    {:ok, credential} = Providers.upsert_credential(scope, "openai", %{"api_key" => "sk-valid"})
    assert {:ok, _} = Providers.delete_credential(scope, credential.id)
    assert {:error, :not_configured} = Providers.fetch_config(workspace.id, "openai")
  end

  test "default model set, read, and clear", %{scope: scope, workspace: workspace} do
    assert Providers.default_model(scope) == nil

    assert {:ok, _} = Providers.set_default_model(scope, "echo", "echo-1")

    assert Providers.default_model(scope) == %{
             "provider_plugin_id" => "echo",
             "model" => "echo-1"
           }

    assert Providers.default_model_for_workspace(workspace.id)["model"] == "echo-1"

    assert {:ok, _} = Providers.set_default_model(scope, "", "")
    assert Providers.default_model(scope) == nil
  end

  test "iteration node runs a published sub-flux per item end-to-end", %{scope: scope} do
    # Sub-flux: echoes {{sys.item}} through the echo model into its answer.
    {:ok, subflux} = Flux.Workflows.create_workflow(scope, %{"name" => "Per Item"})

    sub_graph =
      update_in(subflux.graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node ->
            node
            |> put_in(["config", "provider_plugin_id"], "echo")
            |> put_in(["config", "model"], "echo-1")
            |> put_in(["config", "prompt"], "{{sys.item}}")

          %{"id" => "start"} = node ->
            put_in(node, ["config", "variables"], [])

          node ->
            node
        end)
      end)

    {:ok, subflux} = Flux.Workflows.update_draft(scope, subflux, sub_graph)
    {:ok, _version} = Flux.Workflows.publish(scope, subflux)

    # Parent: iterate a JSON list from the start input through the sub-flux.
    {:ok, parent} = Flux.Workflows.create_workflow(scope, %{"name" => "Parent"})

    parent_graph = %{
      "nodes" => [
        %{
          "id" => "start",
          "type" => "start",
          "title" => "Start",
          "position" => %{"x" => 0, "y" => 0},
          "config" => %{
            "variables" => [
              %{"name" => "items", "label" => "Items", "type" => "paragraph", "required" => true}
            ]
          }
        },
        %{
          "id" => "iter_1",
          "type" => "iteration",
          "title" => "Iterate",
          "position" => %{"x" => 300, "y" => 0},
          "config" => %{
            "variable" => "start.items",
            "workflow_id" => subflux.id,
            "max_items" => 10
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "start",
          "source_handle" => "default",
          "target" => "iter_1"
        }
      ]
    }

    {:ok, parent} = Flux.Workflows.update_draft(scope, parent, parent_graph)
    {:ok, _run} = Flux.Workflows.start_run(scope, parent, %{"items" => ~s(["one","two"])})

    finished =
      receive do
        {:run_finished, finished} -> finished
      after
        5_000 -> flunk("run did not finish")
      end

    assert finished.status == :succeeded
    assert finished.outputs["count"] == 2
    assert [first, second] = finished.outputs["output"]
    assert first["answer"] =~ "You said: one"
    assert second["answer"] =~ "You said: two"
  end

  test "a subflux_version pin runs that version, not the latest", %{scope: scope} do
    {:ok, subflux} = Flux.Workflows.create_workflow(scope, %{"name" => "Pinned"})

    graph_saying = fn text ->
      update_in(subflux.graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "llm_1"} = node ->
            node
            |> put_in(["config", "provider_plugin_id"], "echo")
            |> put_in(["config", "model"], "echo-1")
            |> put_in(["config", "prompt"], text)

          %{"id" => "start"} = node ->
            put_in(node, ["config", "variables"], [])

          node ->
            node
        end)
      end)
    end

    {:ok, subflux} = Flux.Workflows.update_draft(scope, subflux, graph_saying.("version one"))
    {:ok, _v1} = Flux.Workflows.publish(scope, subflux)
    {:ok, subflux} = Flux.Workflows.update_draft(scope, subflux, graph_saying.("version two"))
    {:ok, _v2} = Flux.Workflows.publish(scope, subflux)

    {:ok, parent} = Flux.Workflows.create_workflow(scope, %{"name" => "Pin Parent"})

    parent_graph = fn pin ->
      %{
        "nodes" => [
          %{
            "id" => "start",
            "type" => "start",
            "title" => "Start",
            "position" => %{"x" => 0, "y" => 0},
            "config" => %{
              "variables" => [
                %{
                  "name" => "items",
                  "label" => "Items",
                  "type" => "paragraph",
                  "required" => true
                }
              ]
            }
          },
          %{
            "id" => "iter_1",
            "type" => "iteration",
            "title" => "Iterate",
            "position" => %{"x" => 300, "y" => 0},
            "config" =>
              %{"variable" => "start.items", "workflow_id" => subflux.id}
              |> Map.merge(pin)
          }
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "source_handle" => "default", "target" => "iter_1"}
        ]
      }
    end

    run_and_collect = fn pin ->
      {:ok, parent} = Flux.Workflows.update_draft(scope, parent, parent_graph.(pin))
      {:ok, _run} = Flux.Workflows.start_run(scope, parent, %{"items" => ~s(["x"])})

      receive do
        {:run_finished, finished} -> finished
      after
        5_000 -> flunk("run did not finish")
      end
    end

    pinned = run_and_collect.(%{"subflux_version" => "v1"})
    assert pinned.status == :succeeded
    assert [%{"answer" => answer}] = pinned.outputs["output"]
    assert answer =~ "version one"

    unpinned = run_and_collect.(%{})
    assert [%{"answer" => answer}] = unpinned.outputs["output"]
    assert answer =~ "version two"

    ghost = run_and_collect.(%{"subflux_version" => "v9"})
    assert ghost.status == :failed
    assert ghost.error =~ "version v9 does not exist"
  end

  test "workflow LLM node without a model falls back to the workspace default", %{scope: scope} do
    {:ok, _} = Providers.set_default_model(scope, "echo", "echo-1")

    # Starter graph's llm_1 node keeps its blank provider/model config.
    {:ok, workflow} = Flux.Workflows.create_workflow(scope, %{"name" => "Default Model Flux"})
    {:ok, run} = Flux.Workflows.start_run(scope, workflow, %{"query" => "default ping"})

    finished =
      receive do
        {:run_finished, finished} -> finished
      after
        5_000 -> flunk("run did not finish")
      end

    assert finished.status == :succeeded
    assert run.id == finished.id
    assert finished.outputs["answer"] =~ "You said: default ping"
  end
end
