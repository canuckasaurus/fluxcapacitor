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

  test "image parts are encoded onto the wire for each provider" do
    image = %{data: Base.encode64("fakepng"), media_type: "image/png"}

    message = %{role: :user, content: "what is this?", images: [image]}
    request = %Request{model: "m", messages: [message]}

    # OpenAI: content becomes text + image_url data-URI parts.
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [%{"content" => [text_part, image_part]}] = Jason.decode!(body)["messages"]
      assert text_part == %{"type" => "text", "text" => "what is this?"}
      assert image_part["image_url"]["url"] =~ "data:image/png;base64,"
      sse_response(conn, [~s({"choices":[{"delta":{"content":"a png"}}]}), "[DONE]"])
    end)

    {result, _chunks} =
      collect_chunks(fn emit -> OpenAI.invoke_llm(%{"api_key" => "sk-x"}, request, emit) end)

    assert {:ok, %{content: "a png"}} = result

    # Anthropic: base64 image source blocks before the text.
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [%{"content" => [image_block, text_block]}] = Jason.decode!(body)["messages"]
      assert image_block["source"]["media_type"] == "image/png"
      assert image_block["source"]["type"] == "base64"
      assert text_block["text"] == "what is this?"
      sse_response(conn, [~s({"type":"content_block_delta","delta":{"text":"ok"}})])
    end)

    {result, _chunks} =
      collect_chunks(fn emit -> Anthropic.invoke_llm(%{"api_key" => "sk-a"}, request, emit) end)

    assert {:ok, %{content: "ok"}} = result

    # Gemini: inline_data parts alongside the text.
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [%{"parts" => [text_part, image_part]}] = Jason.decode!(body)["contents"]
      assert text_part["text"] == "what is this?"
      assert image_part["inline_data"]["mime_type"] == "image/png"
      sse_response(conn, [~s({"candidates":[{"content":{"parts":[{"text":"ok"}]}}]})])
    end)

    {result, _chunks} =
      collect_chunks(fn emit -> Gemini.invoke_llm(%{"api_key" => "AIza"}, request, emit) end)

    assert {:ok, %{content: "ok"}} = result
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

  describe "utility tool plugin" do
    alias Flux.Plugins.Utility

    test "calculator evaluates arithmetic safely" do
      assert {:ok, %{text: "22"}} =
               Utility.invoke(%{}, "calculate", %{"expression" => "(2 + 3) * 4 + 2"})

      assert {:ok, %{data: %{"result" => result}}} =
               Utility.invoke(%{}, "calculate", %{"expression" => "-3.5 / 2"})

      assert_in_delta result, -1.75, 0.0001

      assert {:error, message} = Utility.invoke(%{}, "calculate", %{"expression" => "1 / 0"})
      assert message =~ "division by zero"

      assert {:error, _} =
               Utility.invoke(%{}, "calculate", %{"expression" => "System.cmd(\"rm\")"})
    end

    test "current_time returns ISO 8601 and operations are listed" do
      assert {:ok, %{text: text}} = Utility.invoke(%{}, "current_time", %{})
      assert {:ok, _dt, 0} = DateTime.from_iso8601(text)

      operations = Utility.operations(%{})
      assert Enum.map(operations, & &1.id) == ["current_time", "calculate"]
      assert {:ok, _ops} = Flux.PluginRuntime.tool_operations("utility", %{})
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

    test "azure routes per-deployment with api-key auth and estimates missing usage" do
      alias Flux.Plugins.AzureOpenAI

      credentials = %{
        "endpoint" => "https://my-res.openai.azure.com/",
        "api_key" => "azkey",
        "deployments" => "gpt-4o|Prod GPT-4o",
        "embedding_deployments" => "embed-3"
      }

      assert [
               %{name: "gpt-4o", label: "Prod GPT-4o", type: :llm},
               %{name: "embed-3", type: :text_embedding}
             ] = AzureOpenAI.models(credentials)

      Req.Test.stub(Flux.ProviderStub, fn conn ->
        assert conn.host == "my-res.openai.azure.com"
        assert conn.request_path == "/openai/deployments/gpt-4o/chat/completions"
        assert conn.query_string == "api-version=2024-06-01"
        assert Plug.Conn.get_req_header(conn, "api-key") == ["azkey"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        # GA api-versions reject stream_options; the request must omit it.
        refute Map.has_key?(Jason.decode!(body), "stream_options")

        sse_response(conn, [
          ~s({"choices":[{"delta":{"content":"Azure hi"}}]}),
          "[DONE]"
        ])
      end)

      {result, chunks} =
        collect_chunks(fn emit ->
          AzureOpenAI.invoke_llm(credentials, %{request() | model: "gpt-4o"}, emit)
        end)

      assert {:ok, final} = result
      assert final.content == "Azure hi"
      assert chunks == ["Azure hi"]
      # No usage frame arrived, so tokens are the bytes/4 estimate — never zero.
      assert final.usage.input_tokens > 0
      assert final.usage.output_tokens > 0
    end

    test "azure validation demands endpoint, key, and deployments" do
      alias Flux.Plugins.AzureOpenAI

      assert {:error, "Endpoint is required."} = AzureOpenAI.validate_credentials(%{})

      assert {:error, "API key is required."} =
               AzureOpenAI.validate_credentials(%{"endpoint" => "https://r.openai.azure.com"})

      assert {:error, "List at least one chat deployment."} =
               AzureOpenAI.validate_credentials(%{
                 "endpoint" => "https://r.openai.azure.com",
                 "api_key" => "k"
               })

      Req.Test.stub(Flux.ProviderStub, fn conn -> Plug.Conn.send_resp(conn, 401, "no") end)

      assert {:error, "Invalid API key."} =
               AzureOpenAI.validate_credentials(%{
                 "endpoint" => "https://r.openai.azure.com",
                 "api_key" => "bad",
                 "deployments" => "gpt-4o"
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

  describe "bedrock" do
    alias Flux.Plugins.Bedrock

    @bedrock_credentials %{
      "access_key_id" => "AKIAEXAMPLE",
      "secret_access_key" => "wJalrXUtnFEMI",
      "region" => "us-east-1"
    }

    test "blank model list falls back to common Claude ids" do
      assert Enum.all?(Bedrock.models(%{}), &String.starts_with?(&1.name, "anthropic."))

      assert [%{name: "us.anthropic.claude-x:0", label: "Claude X"}] =
               Bedrock.models(%{"models" => "us.anthropic.claude-x:0|Claude X"})
    end

    test "invoke signs with SigV4 and parses the Messages reply" do
      Req.Test.stub(Flux.ProviderStub, fn conn ->
        assert conn.host == "bedrock-runtime.us-east-1.amazonaws.com"
        assert conn.request_path == "/model/anthropic.claude-3-haiku-20240307-v1%3A0/invoke"

        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        assert authorization =~ "AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/"
        assert authorization =~ "/us-east-1/bedrock/aws4_request"
        assert authorization =~ "SignedHeaders=host;x-amz-date"
        assert [_date] = Plug.Conn.get_req_header(conn, "x-amz-date")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["anthropic_version"] == "bedrock-2023-05-31"
        assert [%{"role" => "user", "content" => "hi"}] = decoded["messages"]

        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => "Great Scott!"},
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "lookup",
              "input" => %{"q" => "z"}
            }
          ],
          "stop_reason" => "tool_use",
          "usage" => %{"input_tokens" => 11, "output_tokens" => 4}
        })
      end)

      request = %{request() | model: "anthropic.claude-3-haiku-20240307-v1:0"}

      {result, chunks} =
        collect_chunks(fn emit -> Bedrock.invoke_llm(@bedrock_credentials, request, emit) end)

      assert {:ok, final} = result
      assert final.content == "Great Scott!"
      assert final.finish_reason == :tool_calls
      assert [%{id: "toolu_1", name: "lookup", arguments: %{"q" => "z"}}] = final.tool_calls
      assert final.usage == %{input_tokens: 11, output_tokens: 4}
      # Non-streaming reply arrives as one emitted chunk.
      assert chunks == ["Great Scott!"]
    end

    test "session tokens join the signed headers" do
      Req.Test.stub(Flux.ProviderStub, fn conn ->
        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        assert authorization =~ "SignedHeaders=host;x-amz-date;x-amz-security-token"
        assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["sts-token"]
        Req.Test.json(conn, %{"content" => [], "stop_reason" => "end_turn"})
      end)

      credentials = Map.put(@bedrock_credentials, "session_token", "sts-token")
      request = %{request() | model: "anthropic.claude-3-haiku-20240307-v1:0"}

      assert {:ok, _final} = Bedrock.invoke_llm(credentials, request, fn _chunk -> :ok end)
    end

    test "non-anthropic ids and missing credentials fail honestly" do
      request = %{request() | model: "meta.llama3-70b-instruct-v1:0"}

      assert {:error, message} =
               Bedrock.invoke_llm(@bedrock_credentials, request, fn _c -> :ok end)

      assert message =~ "anthropic.* model ids only"

      assert {:error, "Access key id is required."} = Bedrock.validate_credentials(%{})

      assert {:error, "Region is required."} =
               Bedrock.validate_credentials(%{
                 "access_key_id" => "AKIA",
                 "secret_access_key" => "s"
               })

      Req.Test.stub(Flux.ProviderStub, fn conn ->
        assert conn.host == "bedrock.us-east-1.amazonaws.com"
        assert conn.request_path == "/foundation-models"
        Plug.Conn.send_resp(conn, 403, "denied")
      end)

      assert {:error, message} = Bedrock.validate_credentials(@bedrock_credentials)
      assert message =~ "Access denied"

      Req.Test.stub(Flux.ProviderStub, fn conn -> Req.Test.json(conn, %{"models" => []}) end)
      assert :ok = Bedrock.validate_credentials(@bedrock_credentials)
    end
  end
end
