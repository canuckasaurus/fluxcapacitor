defmodule Flux.Plugins.OllamaTest do
  use ExUnit.Case, async: false

  alias Flux.Plugins.Ollama

  setup do
    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, OllamaStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    :ok
  end

  test "models auto-discover from /api/tags" do
    Req.Test.stub(OllamaStub, fn conn ->
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [%{"name" => "llama3.2:3b"}, %{"name" => "qwen2.5-coder:7b"}]
      })
    end)

    assert [%{name: "llama3.2:3b"}, %{name: "qwen2.5-coder:7b"}] =
             Ollama.models(%{"base_url" => "http://ollama.example.com:11434"})
  end

  test "validate_credentials distinguishes empty, present, and unreachable" do
    Req.Test.stub(OllamaStub, fn conn ->
      Req.Test.json(conn, %{"models" => []})
    end)

    assert {:error, message} =
             Ollama.validate_credentials(%{"base_url" => "http://ollama.example.com:11434"})

    assert message =~ "ollama pull"

    Req.Test.stub(OllamaStub, fn conn ->
      Req.Test.json(conn, %{"models" => [%{"name" => "llama3.2:3b"}]})
    end)

    assert :ok = Ollama.validate_credentials(%{"base_url" => "http://ollama.example.com:11434"})
  end

  test "chat rides the OpenAI-compatible SSE surface under /v1" do
    frames = [
      Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "hello "}}]}),
      Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "from ollama"}}]}),
      Jason.encode!(%{
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4}
      }),
      "[DONE]"
    ]

    Req.Test.stub(OllamaStub, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["model"] == "llama3.2:3b"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, Enum.map_join(frames, "", &("data: " <> &1 <> "\n\n")))
    end)

    request = %Flux.Plugin.ModelProvider.Request{
      model: "llama3.2:3b",
      messages: [%{role: :user, content: "hi"}]
    }

    assert {:ok, result} =
             Ollama.invoke_llm(
               %{"base_url" => "http://ollama.example.com:11434"},
               request,
               fn _chunk -> :ok end
             )

    assert result.content == "hello from ollama"
    assert result.usage.input_tokens == 3
  end
end
