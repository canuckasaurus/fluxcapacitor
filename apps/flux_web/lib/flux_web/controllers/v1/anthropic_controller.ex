defmodule FluxWeb.V1.AnthropicController do
  @moduledoc """
  Anthropic-compatible `POST /v1/messages` with an `app-` bearer token —
  Claude SDKs point at an app with a base-URL swap, beside the OpenAI
  surface. Text-only (no tool use); the request's `model` is ignored,
  the app decides. Streaming follows Anthropic's event sequence
  (`message_start` → `content_block_delta` … → `message_stop`).
  """
  use FluxWeb, :controller

  alias Flux.Chat

  @stream_timeout :timer.minutes(5)

  def create(conn, params) do
    app = conn.assigns[:service_app]

    cond do
      app == nil ->
        anthropic_error(conn, 401, "authentication_error", "This endpoint needs an app- token.")

      Chat.quota_exceeded?(app) ->
        anthropic_error(conn, 429, "rate_limit_error", "The app's daily token limit is spent.")

      true ->
        with {:ok, messages} <- normalize_messages(params["messages"], params["system"]),
             :ok <- guard_input(app, messages) do
          respond(conn, app, messages, params["stream"] == true)
        else
          {:error, :bad_messages} ->
            anthropic_error(
              conn,
              400,
              "invalid_request_error",
              "messages must be a non-empty array of user/assistant turns."
            )

          {:error, :guardrail} ->
            anthropic_error(
              conn,
              400,
              "invalid_request_error",
              "This content isn't allowed here."
            )
        end
    end
  end

  defp invoke_completion(%{mode: :advanced_chat} = app, messages, emit),
    do: Chat.stateless_chatflow_completion(app, messages, emit)

  defp invoke_completion(app, messages, emit),
    do: Chat.stateless_completion(app, messages, emit)

  defp respond(conn, app, messages, false) do
    case invoke_completion(app, messages, fn _chunk -> :ok end) do
      {:ok, result, model_used} ->
        json(conn, %{
          "id" => message_id(),
          "type" => "message",
          "role" => "assistant",
          "model" => model_used,
          "content" => [%{"type" => "text", "text" => result.content}],
          "stop_reason" => "end_turn",
          "stop_sequence" => nil,
          "usage" => usage(result)
        })

      {:error, reason} ->
        anthropic_error(conn, 502, "api_error", "The model errored: #{inspect(reason)}")
    end
  end

  defp respond(conn, app, messages, true) do
    parent = self()
    id = message_id()

    Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
      emit = fn %{delta: delta} -> send(parent, {:delta, delta}) end

      case invoke_completion(app, messages, emit) do
        {:ok, result, model_used} -> send(parent, {:finished, result, model_used})
        {:error, reason} -> send(parent, {:failed, reason})
      end
    end)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    {_, conn} =
      sse(conn, "message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => id,
          "type" => "message",
          "role" => "assistant",
          "model" => app.model || "chatflow",
          "content" => [],
          "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
        }
      })

    {_, conn} =
      sse(conn, "content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      })

    stream_loop(conn)
  end

  defp stream_loop(conn) do
    receive do
      {:delta, delta} ->
        case sse(conn, "content_block_delta", %{
               "type" => "content_block_delta",
               "index" => 0,
               "delta" => %{"type" => "text_delta", "text" => delta}
             }) do
          {:ok, conn} -> stream_loop(conn)
          {:error, _closed} -> conn
        end

      {:finished, result, _model_used} ->
        {_, conn} =
          sse(conn, "content_block_stop", %{"type" => "content_block_stop", "index" => 0})

        {_, conn} =
          sse(conn, "message_delta", %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
            "usage" => %{"output_tokens" => output_tokens(result)}
          })

        {_, conn} = sse(conn, "message_stop", %{"type" => "message_stop"})
        conn

      {:failed, reason} ->
        {_, conn} =
          sse(conn, "error", %{
            "type" => "error",
            "error" => %{
              "type" => "api_error",
              "message" => "The model errored: #{inspect(reason)}"
            }
          })

        conn
    after
      @stream_timeout ->
        {_, conn} = sse(conn, "message_stop", %{"type" => "message_stop"})
        conn
    end
  end

  defp sse(conn, event, payload) do
    chunk(conn, "event: " <> event <> "\ndata: " <> Jason.encode!(payload) <> "\n\n")
  end

  # Anthropic messages: user/assistant turns, content as a string or an
  # array of text blocks; a top-level `system` prepends the system turn.
  defp normalize_messages(messages, system) when is_list(messages) and messages != [] do
    normalized =
      for %{"role" => role, "content" => content} <- messages,
          role in ["user", "assistant"],
          text = content_text(content),
          is_binary(text) and text != "" do
        %{role: String.to_existing_atom(role), content: text}
      end

    case normalized do
      [] ->
        {:error, :bad_messages}

      turns ->
        case to_string(system || "") do
          "" -> {:ok, turns}
          system_text -> {:ok, [%{role: :system, content: system_text} | turns]}
        end
    end
  end

  defp normalize_messages(_other, _system), do: {:error, :bad_messages}

  defp content_text(content) when is_binary(content), do: content

  defp content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp content_text(_other), do: nil

  defp guard_input(app, messages) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find_value("", fn message ->
        message.role == :user && message.content
      end)

    Flux.Guardrails.check_input(app.workspace_id, last_user, "chat input (#{app.name})")
  end

  defp usage(result) do
    %{
      "input_tokens" => tokens(result, :input_tokens),
      "output_tokens" => tokens(result, :output_tokens)
    }
  end

  defp output_tokens(result), do: tokens(result, :output_tokens)

  defp tokens(result, key) do
    usage = Map.get(result, :usage) || %{}
    usage[key] || usage[to_string(key)] || 0
  end

  defp message_id, do: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp anthropic_error(conn, status, type, message) do
    conn
    |> put_status(status)
    |> json(%{"type" => "error", "error" => %{"type" => type, "message" => message}})
  end
end
