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

  test "non-200 responses become http_error tuples" do
    Req.Test.stub(Flux.ProviderStub, fn conn ->
      Plug.Conn.send_resp(conn, 401, ~s({"error":"bad key"}))
    end)

    assert {:error, {:http_error, 401, _body}} =
             OpenAI.invoke_llm(%{"api_key" => "bad"}, request(), fn _chunk -> :ok end)

    assert {:error, "Invalid API key."} = Gemini.validate_credentials(%{"api_key" => "bad"})
    assert {:error, "Invalid API key."} = Anthropic.validate_credentials(%{"api_key" => "bad"})
  end
end
