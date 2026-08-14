defmodule FluxWeb.V1.AppResourceController do
  @moduledoc """
  interoperable app-token resources: `GET /parameters`,
  `GET /conversations`, `GET /messages`, `POST /chat-messages/:id/stop`,
  `POST /messages/:id/feedbacks`. All require an `app-…` token.
  """
  use FluxWeb, :controller

  alias Flux.Chat

  plug :require_app_token when action not in [:spec]

  @doc "The OpenAPI contract for the /v1 surface (any valid service token)."
  def spec(conn, _params) do
    json(conn, OpenApiSpex.OpenApi.to_map(FluxWeb.V1.ApiSpec.spec()))
  end

  def parameters(conn, _params) do
    app = conn.assigns.service_app

    json(conn, %{
      opening_statement: app.opening_statement,
      suggested_questions: app.suggested_questions,
      user_input_form:
        for field <- app.input_form do
          %{
            (field["type"] || "text-input") => %{
              label: (field["label"] not in [nil, ""] && field["label"]) || field["variable"],
              variable: field["variable"],
              required: field["required"] == true,
              default: ""
            }
          }
        end,
      model: %{provider: app.provider_plugin_id, name: app.model}
    })
  end

  def conversations(conn, params) do
    limit = parse_limit(params["limit"])
    scope = conn.assigns.service_scope
    conversations = Chat.list_conversations(scope, conn.assigns.service_app.id, limit)

    json(conn, %{
      limit: limit,
      has_more: length(conversations) == limit,
      data:
        for conversation <- conversations do
          %{
            id: conversation.id,
            name: conversation.title,
            created_at: DateTime.to_unix(conversation.inserted_at)
          }
        end
    })
  end

  def messages(conn, %{"conversation_id" => conversation_id}) do
    scope = conn.assigns.service_scope

    case Chat.get_conversation(scope, conversation_id) do
      {:error, :not_found} ->
        error(conn, 404, "not_found", "Conversation not found")

      conversation ->
        if conversation.app_id == conn.assigns.service_app.id do
          messages = Chat.list_messages(scope, conversation.id)

          json(conn, %{
            data:
              for message <- messages do
                %{
                  id: message.id,
                  conversation_id: conversation.id,
                  role: message.role,
                  content: message.content,
                  status: message.status,
                  feedback: message.feedback,
                  files: message.usage["files"] || [],
                  created_at: DateTime.to_unix(message.inserted_at)
                }
              end
          })
        else
          error(conn, 404, "not_found", "Conversation not found")
        end
    end
  end

  def messages(conn, _params) do
    error(conn, 400, "invalid_param", "conversation_id is required")
  end

  def stop(conn, %{"id" => message_id}) do
    case Chat.stop_generation(conn.assigns.service_scope, message_id) do
      {:ok, _message} -> json(conn, %{result: "success"})
      {:error, :not_streaming} -> error(conn, 400, "not_streaming", "Nothing to stop")
    end
  end

  def feedback(conn, %{"id" => message_id} = params) do
    rating =
      case params["rating"] do
        "like" -> :like
        "dislike" -> :dislike
        _clear -> nil
      end

    case Chat.set_feedback(conn.assigns.service_scope, message_id, rating,
           comment: params["content"]
         ) do
      {:ok, _message} -> json(conn, %{result: "success"})
      {:error, :not_found} -> error(conn, 404, "not_found", "Message not found")
    end
  end

  def meta(conn, _params) do
    json(conn, %{tool_icons: %{}})
  end

  def rename_conversation(conn, %{"id" => id} = params) do
    name = to_string(params["name"] || "")

    with true <- name != "",
         {:ok, conversation} <-
           Chat.rename_conversation(conn.assigns.service_scope, id, name) do
      json(conn, %{
        id: conversation.id,
        name: conversation.title,
        created_at: DateTime.to_unix(conversation.inserted_at)
      })
    else
      false -> error(conn, 400, "invalid_param", "name is required")
      {:error, :not_found} -> error(conn, 404, "not_found", "Conversation not found")
    end
  end

  def delete_conversation(conn, %{"id" => id}) do
    case Chat.delete_conversation(conn.assigns.service_scope, id) do
      {:ok, _conversation} -> json(conn, %{result: "success"})
      {:error, :not_found} -> error(conn, 404, "not_found", "Conversation not found")
    end
  end

  def upload_file(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    attrs = %{
      path: upload.path,
      filename: upload.filename,
      content_type: upload.content_type,
      end_user_ref: params["user"]
    }

    case Chat.create_upload(conn.assigns.service_scope, conn.assigns.service_app, attrs) do
      {:ok, file} ->
        json(conn, %{
          id: file.id,
          name: file.name,
          size: file.size,
          extension: file.name |> Path.extname() |> String.trim_leading("."),
          mime_type: file.content_type,
          created_at: DateTime.to_unix(file.inserted_at)
        })

      {:error, :too_large} ->
        error(conn, 413, "file_too_large", "Files are limited to 15 MB")

      {:error, reason} ->
        error(conn, 500, "upload_failed", "Could not store the file: #{inspect(reason)}")
    end
  end

  def upload_file(conn, _params) do
    error(conn, 400, "invalid_param", "multipart field \"file\" is required")
  end

  defp require_app_token(conn, _opts) do
    if conn.assigns[:service_app] do
      conn
    else
      conn
      |> error(403, "invalid_token_kind", "This endpoint requires an app- token")
      |> halt()
    end
  end

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..100 -> parsed
      _invalid -> 20
    end
  end

  defp parse_limit(_limit), do: 20

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{code: code, message: message, status: status})
  end
end
