defmodule FluxWeb.V1.ChatMessageController do
  @moduledoc """
  FluxCapacitor service API `/v1/chat-messages`: streaming SSE by default
  (`event: message` deltas, then `message_end` with usage), or a single
  JSON document with `response_mode: "blocking"`.
  """
  use FluxWeb, :controller

  alias Flux.Chat
  alias Flux.Chat.Conversation

  @stream_timeout :timer.minutes(5)

  def create(conn, %{"query" => query} = params) when is_binary(query) and query != "" do
    case conn.assigns[:service_app] do
      nil -> error(conn, 403, "invalid_token_kind", "This endpoint requires an app- token")
      app -> create_message(conn, app, params)
    end
  end

  def create(conn, _params) do
    error(conn, 400, "invalid_param", "query is required")
  end

  @doc "FluxCapacitor service API `/v1/completion-messages` for completion-mode apps."
  def completion(conn, params) do
    case conn.assigns[:service_app] do
      nil ->
        error(conn, 403, "invalid_token_kind", "This endpoint requires an app- token")

      app ->
        scope = conn.assigns.service_scope
        inputs = if is_map(params["inputs"]), do: params["inputs"], else: %{}

        case Chat.send_completion(scope, app, inputs, %{end_user_ref: params["user"]}) do
          {:ok, conversation, _user_message, assistant_message} ->
            case Map.get(params, "response_mode", "streaming") do
              "blocking" -> respond_blocking(conn, conversation, assistant_message)
              _streaming -> respond_streaming(conn, conversation, assistant_message)
            end

          {:error, :not_completion_app} ->
            error(conn, 400, "invalid_app_mode", "This app is not a completion app")

          {:error, :guardrail} ->
            error(conn, 403, "guardrail", "This message violates the workspace guardrails")

          {:error, :quota_exceeded} ->
            error(conn, 429, "quota_exceeded", "This app's daily token limit is spent")
        end
    end
  end

  defp create_message(conn, app, %{"query" => query} = params) do
    scope = conn.assigns.service_scope

    case resolve_conversation(scope, app, params) do
      {:ok, conversation} ->
        files = resolve_files(scope, params["files"])

        case Chat.send_message(scope, app, conversation, query, files: files) do
          {:ok, _user_message, assistant_message} ->
            case Map.get(params, "response_mode", "streaming") do
              "blocking" -> respond_blocking(conn, conversation, assistant_message)
              _ -> respond_streaming(conn, conversation, assistant_message)
            end

          {:error, :guardrail} ->
            error(conn, 403, "guardrail", "This message violates the workspace guardrails")

          {:error, :quota_exceeded} ->
            error(conn, 429, "quota_exceeded", "This app's daily token limit is spent")
        end

      {:error, :not_found} ->
        error(conn, 404, "not_found", "Conversation not found")
    end
  end

  defp resolve_conversation(scope, app, %{"conversation_id" => id})
       when is_binary(id) and id != "" do
    case Chat.get_conversation(scope, id) do
      %Conversation{app_id: app_id} = conversation when app_id == app.id -> {:ok, conversation}
      _ -> {:error, :not_found}
    end
  end

  defp resolve_conversation(scope, app, params) do
    {:ok, Chat.create_conversation(scope, app, %{end_user_ref: params["user"]})}
  end

  # Reference-compatible files param: [%{"type" => "image",
  # "transfer_method" => "local_file", "upload_file_id" => id}]. Only
  # image uploads that exist in this workspace are attached.
  defp resolve_files(scope, files) when is_list(files) do
    for %{"upload_file_id" => id} <- files,
        is_binary(id),
        match?({:ok, _}, Ecto.UUID.cast(id)),
        %Flux.Chat.UploadedFile{content_type: "image/" <> _} = file <-
          [Chat.get_uploaded_file(scope, id)] do
      file
    end
  end

  defp resolve_files(_scope, _files), do: []

  ## Streaming

  defp respond_streaming(conn, conversation, assistant_message) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    stream_loop(conn, conversation, assistant_message)
  end

  defp stream_loop(conn, conversation, assistant_message) do
    receive do
      {:chunk, delta} ->
        case sse(conn, %{
               event: "message",
               message_id: assistant_message.id,
               conversation_id: conversation.id,
               answer: delta
             }) do
          {:ok, conn} -> stream_loop(conn, conversation, assistant_message)
          {:error, _closed} -> conn
        end

      {:done, message} ->
        {_, conn} =
          sse(conn, %{
            event: "message_end",
            message_id: message.id,
            conversation_id: conversation.id,
            metadata: %{
              usage: message.usage,
              retriever_resources: retriever_resources(message)
            }
          })

        conn

      {:error, message} ->
        {_, conn} =
          sse(conn, %{
            event: "error",
            message_id: message.id,
            conversation_id: conversation.id,
            code: "generation_failed",
            message: message.error
          })

        conn
    after
      @stream_timeout ->
        {_, conn} = sse(conn, %{event: "error", code: "timeout", message: "Stream timed out"})
        conn
    end
  end

  defp sse(conn, payload), do: chunk(conn, "data: " <> Jason.encode!(payload) <> "\n\n")

  ## Blocking

  defp respond_blocking(conn, conversation, assistant_message) do
    receive do
      {:chunk, _delta} ->
        respond_blocking(conn, conversation, assistant_message)

      {:done, message} ->
        json(conn, %{
          event: "message",
          message_id: message.id,
          conversation_id: conversation.id,
          mode: "chat",
          answer: message.content,
          metadata: %{
            usage: message.usage,
            retriever_resources: retriever_resources(message)
          },
          created_at: DateTime.to_unix(message.inserted_at)
        })

      {:error, message} ->
        error(conn, 500, "generation_failed", message.error || "Generation failed")
    after
      @stream_timeout ->
        error(conn, 504, "timeout", "Generation timed out")
    end
  end

  # Knowledge citations in the reference API's shape: chatflow knowledge
  # nodes store them on the message, straight chat apps have none.
  defp retriever_resources(%{citations: citations}) when is_list(citations) do
    for {citation, index} <- Enum.with_index(citations, 1) do
      %{
        position: index,
        dataset_id: citation["dataset_id"],
        document_id: citation["document_id"],
        document_name: citation["document"],
        content: citation["content"],
        score: citation["score"]
      }
    end
  end

  defp retriever_resources(_message), do: []

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{code: code, message: message, status: status})
  end
end
