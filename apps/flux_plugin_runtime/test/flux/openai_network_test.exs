defmodule Flux.OpenAINetworkTest do
  # Every other provider test stubs HTTP with `plug: {Req.Test, …}`, which
  # routes the request into an in-process Plug — the wire is never touched,
  # so a transport regression (a Req upgrade, a Finch pool change) could
  # zero out real network calls while the suite stays green. These tests
  # run the OpenAI plugin against a bare :gen_tcp HTTP server: if no
  # actual TCP request arrives, they fail.
  use ExUnit.Case, async: false

  alias Flux.Plugins.OpenAI

  setup do
    # No req_options plug may leak in from another test — real transport only.
    previous_req = Application.get_env(:flux_plugin_runtime, :req_options)
    Application.delete_env(:flux_plugin_runtime, :req_options)

    # SSRF guards production against internal addresses; this test IS an
    # internal address, deliberately.
    previous_ssrf = Application.get_env(:flux, Flux.SSRF)
    Application.put_env(:flux, Flux.SSRF, allow: ["127.0.0.1"])

    on_exit(fn ->
      if previous_req,
        do: Application.put_env(:flux_plugin_runtime, :req_options, previous_req),
        else: Application.delete_env(:flux_plugin_runtime, :req_options)

      if previous_ssrf,
        do: Application.put_env(:flux, Flux.SSRF, previous_ssrf),
        else: Application.delete_env(:flux, Flux.SSRF)
    end)

    :ok
  end

  test "invoke_llm makes a real HTTP request and parses the SSE stream" do
    test_pid = self()

    sse_body =
      [
        ~s|data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n|,
        ~s|data: {"choices":[{"delta":{"content":"world"},"finish_reason":"stop"}]}\n\n|,
        ~s|data: {"usage":{"prompt_tokens":7,"completion_tokens":2}}\n\n|,
        ~s|data: [DONE]\n\n|
      ]
      |> IO.iodata_to_binary()

    port =
      start_one_shot_server(fn request ->
        send(test_pid, {:request, request})

        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n" <>
          sse_body
      end)

    credentials = %{"api_key" => "sk-net-test", "base_url" => "http://127.0.0.1:#{port}"}

    request = %Flux.Plugin.ModelProvider.Request{
      model: "gpt-4o-mini",
      messages: [%{role: :user, content: "hi over the wire"}],
      params: %{temperature: 0.5}
    }

    chunks_pid = self()

    assert {:ok, result} =
             OpenAI.invoke_llm(credentials, request, fn chunk ->
               send(chunks_pid, {:chunk, chunk.delta})
             end)

    # The reply was parsed from bytes that crossed a real socket.
    assert result.content == "Hello world"
    assert result.usage == %{input_tokens: 7, output_tokens: 2}
    assert_received {:chunk, "Hello "}
    assert_received {:chunk, "world"}

    # And the request that arrived over TCP is the one we meant to send.
    assert_receive {:request, request_text}, 2_000
    [head, body] = String.split(request_text, "\r\n\r\n", parts: 2)
    assert head =~ "POST /chat/completions HTTP/1.1"
    assert head =~ ~r/authorization: Bearer sk-net-test/i

    decoded = Jason.decode!(body)
    assert decoded["model"] == "gpt-4o-mini"
    assert decoded["stream"] == true
    assert decoded["temperature"] == 0.5
    assert [%{"role" => "user", "content" => "hi over the wire"}] = decoded["messages"]
  end

  test "invoke_embeddings makes a real HTTP request and parses vectors" do
    test_pid = self()

    response_json =
      Jason.encode!(%{
        "data" => [
          %{"index" => 0, "embedding" => [0.1, 0.2]},
          %{"index" => 1, "embedding" => [0.3, 0.4]}
        ],
        "usage" => %{"prompt_tokens" => 5}
      })

    port =
      start_one_shot_server(fn request ->
        send(test_pid, {:request, request})

        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(response_json)}\r\nconnection: close\r\n\r\n" <>
          response_json
      end)

    credentials = %{"api_key" => "sk-net-test", "base_url" => "http://127.0.0.1:#{port}"}

    assert {:ok, %{vectors: [[0.1, 0.2], [0.3, 0.4]], usage: %{input_tokens: 5}}} =
             OpenAI.invoke_embeddings(credentials, "text-embedding-3-small", ["a", "b"])

    assert_receive {:request, request_text}, 2_000
    assert request_text =~ "POST /embeddings HTTP/1.1"
    assert request_text =~ "text-embedding-3-small"
  end

  test "without the SSRF allowance the loopback call is refused before any I/O" do
    Application.put_env(:flux, Flux.SSRF, [])

    credentials = %{"api_key" => "sk", "base_url" => "http://127.0.0.1:9"}

    request = %Flux.Plugin.ModelProvider.Request{
      model: "gpt-4o-mini",
      messages: [%{role: :user, content: "hi"}],
      params: %{}
    }

    assert {:error, message} = OpenAI.invoke_llm(credentials, request, fn _chunk -> :ok end)
    assert message =~ "blocked address"
  end

  # A single-request HTTP server on a random loopback port: accepts one
  # connection, reads the full request (headers + content-length body),
  # answers with whatever `respond` returns, and closes.
  defp start_one_shot_server(respond) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 10_000)
      request = read_request(socket, "")
      :ok = :gen_tcp.send(socket, respond.(request))
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp read_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, body] ->
        expected = content_length(head)

        if byte_size(body) >= expected do
          buffer
        else
          {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
          read_request(socket, buffer <> more)
        end

      [_incomplete] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> more)
    end
  end

  defp content_length(head) do
    case Regex.run(~r/content-length:\s*(\d+)/i, head) do
      [_line, length] -> String.to_integer(length)
      nil -> 0
    end
  end
end
