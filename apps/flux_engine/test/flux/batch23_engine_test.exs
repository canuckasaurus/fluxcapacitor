defmodule Flux.Batch23EngineTest do
  use ExUnit.Case, async: true

  alias Flux.Engine.Graph.Node
  alias Flux.Engine.Host
  alias Flux.Engine.Nodes.{LLM, Subflux}

  describe "subflux node" do
    defp subflux_node(config), do: %Node{id: "sub_1", type: "subflux", config: config}

    test "renders input templates and returns the sub-flux outputs" do
      node =
        subflux_node(%{
          "workflow_id" => "wf-x",
          "subflux_version" => "v2",
          "inputs" => %{"query" => "{{start.query}}", "tone" => "friendly"}
        })

      pool = %{"start" => %{"query" => "hello"}}

      host = %Host{
        run_subflux: fn request ->
          send(self(), {:subflux_request, request})
          {:ok, %{"answer" => "hi there"}}
        end
      }

      assert {:ok, %{"answer" => "hi there"}} = Subflux.run(node, pool, host)

      assert_receive {:subflux_request,
                      %{
                        workflow_id: "wf-x",
                        version: 2,
                        inputs: %{"query" => "hello", "tone" => "friendly"}
                      }}
    end

    test "no version pin means no version key (latest published)" do
      node = subflux_node(%{"workflow_id" => "wf-x", "inputs" => %{}})

      host = %Host{
        run_subflux: fn request ->
          send(self(), {:subflux_request, request})
          {:ok, %{}}
        end
      }

      assert {:ok, %{}} = Subflux.run(node, %{}, host)
      assert_receive {:subflux_request, request}
      refute Map.has_key?(request, :version)
    end

    test "a missing flux or capability errors honestly" do
      assert {:error, message} = Subflux.run(subflux_node(%{}), %{}, %Host{})
      assert message =~ "needs a flux"

      node = subflux_node(%{"workflow_id" => "wf-x"})
      assert {:error, message} = Subflux.run(node, %{}, %Host{})
      assert message =~ "cannot run sub-fluxes"
    end

    test "sub-flux failures surface as node errors" do
      node = subflux_node(%{"workflow_id" => "wf-x"})
      host = %Host{run_subflux: fn _request -> {:error, "sub-flux not found"} end}

      assert {:error, "sub-flux not found"} = Subflux.run(node, %{}, host)
    end

    test "subflux is a registered node type" do
      assert Flux.Engine.Node.implementation("subflux") == Subflux
      assert "subflux" in Flux.Engine.Graph.node_types()
    end
  end

  describe "llm node vision" do
    defp llm_node(config) do
      base = %{"provider_plugin_id" => "echo", "model" => "echo-1", "prompt" => "describe this"}
      %Node{id: "llm_1", type: "llm", config: Map.merge(base, config)}
    end

    defp capture_llm_host(extra) do
      struct!(
        %Host{
          emit: fn _event -> :ok end,
          invoke_llm: fn request, _chunk_emit ->
            send(self(), {:llm_messages, request.messages})
            {:ok, %{content: "a cat", usage: %{}}}
          end
        },
        extra
      )
    end

    test "vision_variable loads the image onto the user message" do
      host =
        capture_llm_host(
          read_image: fn %{file_id: "file-123"} ->
            {:ok, %{data: "QkFTRTY0", media_type: "image/png"}}
          end
        )

      node = llm_node(%{"vision_variable" => "start.photo"})
      pool = %{"start" => %{"photo" => "file-123"}}

      assert {:ok, %{"text" => "a cat"}} = LLM.run(node, pool, host)

      assert_receive {:llm_messages, messages}
      assert %{images: [%{data: "QkFTRTY0", media_type: "image/png"}]} = List.last(messages)
    end

    test "without a vision_variable messages stay imageless" do
      assert {:ok, _outputs} = LLM.run(llm_node(%{}), %{}, capture_llm_host([]))

      assert_receive {:llm_messages, messages}
      refute Map.has_key?(List.last(messages), :images)
    end

    test "an unreadable image fails the node instead of silently dropping it" do
      host =
        capture_llm_host(read_image: fn _request -> {:error, "notes.txt is not an image"} end)

      node = llm_node(%{"vision_variable" => "start.photo"})

      assert {:error, "notes.txt is not an image"} =
               LLM.run(node, %{"start" => %{"photo" => "file-9"}}, host)
    end

    test "a host without the capability fails the node" do
      node = llm_node(%{"vision_variable" => "start.photo"})

      assert {:error, message} = LLM.run(node, %{}, capture_llm_host([]))
      assert message =~ "cannot read images"
    end
  end
end
