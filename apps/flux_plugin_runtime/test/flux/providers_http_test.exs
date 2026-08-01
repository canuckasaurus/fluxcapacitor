defmodule Flux.ProvidersHTTPTest do
  use ExUnit.Case, async: false

  alias Flux.Plugin.ModelProvider.{Chunk, Request}
  alias Flux.Plugins.{Anthropic, Gemini, OpenAI}

  setup do
    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.ProviderStub})

    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)
    :ok
  end

  defp sse_response(conn, frames) do
    body = Enum.map_join(frames, "", &("data: " <> &1 <> "\n\n"))

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end

  defp request, do: %Request{model: "m", messages: [%{role: :user, content: "hi"}]}

  defp collect_chunks(fun) do
    parent = self()
    result = fun.(fn %Chunk{delta: delta} -> send(parent, {:delta, delta}) end)
    {result, drain([])}
  end

  defp drain(acc) do
    receive do
      {:delta, delta} -> drain([delta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "openai parses deltas and usage from SSE frames" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      sse_response(conn, [
        ~s({"choices":[{"delta":{"content":"Hel"}}]}),
        ~s({"choices":[{"delta":{"content":"lo"}}]}),
        ~s({"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}),
        "[DONE]"
      ])
    end)

    {result, chunks} =
      collect_chunks(fn emit -> OpenAI.invoke_llm(%{"api_key" => "sk-x"}, request(), emit) end)

    assert {:ok, final} = result
    assert final.content == "Hello"
    assert final.usage == %{input_tokens: 7, output_tokens: 2}
    assert chunks == ["Hel", "lo"]
  end

  test "anthropic parses content_block_delta and usage events" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      sse_response(conn, [
        ~s({"type":"message_start","message":{"usage":{"input_tokens":9}}}),
        ~s({"type":"content_block_delta","delta":{"text":"Bon"}}),
        ~s({"type":"content_block_delta","delta":{"text":"jour"}}),
        ~s({"type":"message_delta","usage":{"output_tokens":3}})
      ])
    end)

    {result, chunks} =
      collect_chunks(fn emit ->
        Anthropic.invoke_llm(%{"api_key" => "sk-ant"}, request(), emit)
      end)

    assert {:ok, final} = result
    assert final.content == "Bonjour"
    assert final.usage == %{input_tokens: 9, output_tokens: 3}
    assert chunks == ["Bon", "jour"]
  end

  test "gemini parses candidate parts and cumulative usageMetadata" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      sse_response(conn, [
        ~s({"candidates":[{"content":{"parts":[{"text":"Ho"}]}}],"usageMetadata":{"promptTokenCount":4}}),
        ~s({"candidates":[{"content":{"parts":[{"text":"la"}]}}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":2}})
      ])
    end)

    {result, chunks} =
      collect_chunks(fn emit -> Gemini.invoke_llm(%{"api_key" => "AIza"}, request(), emit) end)

    assert {:ok, final} = result
    assert final.content == "Hola"
    assert final.usage == %{input_tokens: 4, output_tokens: 2}
    assert chunks == ["Ho", "la"]
  end

  test "malformed frames are skipped without crashing the stream" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      sse_response(conn, [
        ~s({"choices":[{"delta":{"content":"ok"}}]}),
        "{not json",
        ~s({"unexpected":"shape"}),
        "[DONE]"
      ])
    end)

    {result, chunks} =
      collect_chunks(fn emit -> OpenAI.invoke_llm(%{"api_key" => "sk-x"}, request(), emit) end)

    assert {:ok, final} = result
    assert final.content == "ok"
    assert chunks == ["ok"]
  end

  test "openai accumulates streamed tool-call fragments" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert [%{"function" => %{"name" => "get_weather"}}] = decoded["tools"]

      sse_response(conn, [
        ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\":"}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Paris\\"}"}}]},"finish_reason":"tool_calls"}]}),
        "[DONE]"
      ])
    end)

    request = %Request{
      model: "m",
      messages: [%{role: :user, content: "weather?"}],
      tools: [
        %Flux.Plugin.ModelProvider.ToolDef{
          name: "get_weather",
          description: "d",
          parameters: %{"type" => "object"}
        }
      ]
    }

    assert {:ok, final} = OpenAI.invoke_llm(%{"api_key" => "sk"}, request, fn _c -> :ok end)
    assert final.finish_reason == :tool_calls

    assert [%{id: "call_1", name: "get_weather", arguments: %{"city" => "Paris"}}] =
             final.tool_calls
  end

  test "anthropic accumulates input_json_delta tool calls" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      sse_response(conn, [
        ~s({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"lookup"}}),
        ~s({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":"}}),
        ~s({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"x\\"}"}}),
        ~s({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}})
      ])
    end)

    assert {:ok, final} =
             Anthropic.invoke_llm(%{"api_key" => "k"}, request(), fn _c -> :ok end)

    assert final.finish_reason == :tool_calls
    assert [%{id: "toolu_9", name: "lookup", arguments: %{"q" => "x"}}] = final.tool_calls
  end

  test "gemini collects whole functionCall parts" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      sse_response(conn, [
        ~s({"candidates":[{"content":{"parts":[{"functionCall":{"name":"search","args":{"q":"y"}}}]}}]})
      ])
    end)

    assert {:ok, final} = Gemini.invoke_llm(%{"api_key" => "k"}, request(), fn _c -> :ok end)
    assert final.finish_reason == :tool_calls
    assert [%{name: "search", arguments: %{"q" => "y"}}] = final.tool_calls
  end

  test "non-200 responses become http_error tuples" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      Plug.Conn.send_resp(conn, 401, ~s({"error":"bad key"}))
    end)

    assert {:error, {:http_error, 401, _body}} =
             OpenAI.invoke_llm(%{"api_key" => "bad"}, request(), fn _chunk -> :ok end)

    assert {:error, "Invalid API key."} = Gemini.validate_credentials(%{"api_key" => "bad"})
    assert {:error, "Invalid API key."} = Anthropic.validate_credentials(%{"api_key" => "bad"})
  end

  describe "embeddings" do
    test "openai embeddings parse vectors in input order" do
      Req.Test.stub(Flux.ProviderStub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"index" => 1, "embedding" => [0.3, 0.4]},
            %{"index" => 0, "embedding" => [0.1, 0.2]}
          ],
          "usage" => %{"prompt_tokens" => 5}
        })
      end)

      assert {:ok, %{vectors: [[0.1, 0.2], [0.3, 0.4]], usage: %{input_tokens: 5}}} =
               OpenAI.invoke_embeddings(%{"api_key" => "sk-x"}, "text-embedding-3-small", [
                 "one",
                 "two"
               ])
    end

    test "echo embeddings are deterministic and similarity-meaningful" do
      {:ok, %{vectors: [a, b, c]}} =
        Flux.Plugins.Echo.invoke_embeddings(%{}, "echo-embed", [
          "elixir runs on the beam",
          "elixir runs on the beam vm",
          "quantum flux capacitor"
        ])

      cosine = fn x, y -> Enum.zip(x, y) |> Enum.reduce(0.0, fn {p, q}, s -> s + p * q end) end
      assert cosine.(a, b) > cosine.(a, c)

      {:ok, %{vectors: [a2]}} =
        Flux.Plugins.Echo.invoke_embeddings(%{}, "echo-embed", ["elixir runs on the beam"])

      assert a == a2
    end

    test "runtime returns not_supported for plugins without embeddings" do
      assert {:error, :not_supported} =
               Flux.PluginRuntime.invoke_embeddings("anthropic", %{}, "m", ["x"])
    end
  end

  describe "openai_compatible" do
    alias Flux.Plugins.OpenAICompatible

    test "models come from the configured list" do
      specs =
        OpenAICompatible.models(%{"models" => "grok-3, grok-3-mini|Grok 3 Mini , llama3"})

      assert [
               %{name: "grok-3", label: "grok-3"},
               %{name: "grok-3-mini", label: "Grok 3 Mini"},
               %{name: "llama3", label: "llama3"}
             ] = specs
    end

    test "validation requires base_url and models, tolerates missing /models" do
      assert {:error, "Base URL is required."} =
               OpenAICompatible.validate_credentials(%{"models" => "m"})

      assert {:error, "List at least one model name."} =
               OpenAICompatible.validate_credentials(%{"base_url" => "https://example.com/v1"})

      Req.Test.stub(Flux.ProviderStub, fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end)

      assert :ok =
               OpenAICompatible.validate_credentials(%{
                 "base_url" => "https://example.com/v1",
                 "models" => "grok-3"
               })

      Req.Test.stub(Flux.ProviderStub, fn conn -> Plug.Conn.send_resp(conn, 401, "no") end)

      assert {:error, "Invalid API key."} =
               OpenAICompatible.validate_credentials(%{
                 "base_url" => "https://example.com/v1",
                 "api_key" => "bad",
                 "models" => "grok-3"
               })
    end

    test "invoke_llm speaks the OpenAI wire protocol against the configured base_url" do
      Req.Test.stub(Flux.ProviderStub, fn conn ->
        assert conn.host == "grok.example.com"

        sse_response(conn, [
          ~s({"choices":[{"delta":{"content":"xAI says hi"}}]}),
          "[DONE]"
        ])
      end)

      {result, chunks} =
        collect_chunks(fn emit ->
          OpenAICompatible.invoke_llm(
            %{"base_url" => "https://grok.example.com/v1", "api_key" => "xai-1"},
            request(),
            emit
          )
        end)

      assert {:ok, final} = result
      assert final.content == "xAI says hi"
      assert chunks == ["xAI says hi"]
    end
  end
end
