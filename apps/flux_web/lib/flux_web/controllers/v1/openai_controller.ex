defmodule FluxWeb.V1.OpenAIController do
  @moduledoc """
  OpenAI-compatible surface: `POST /v1/chat/completions` with an `app-`
  bearer token maps onto that chat app — swap the base URL and any
  OpenAI SDK talks to FluxCapacitor. Stateless by design (the caller
  supplies the whole history, nothing is persisted); the request's
  `model` field is ignored — the app decides the model. Streaming uses
  OpenAI's `chat.completion.chunk` frames ending in `data: [DONE]`.
  """
  use FluxWeb, :controller

  alias Flux.Chat

  @stream_timeout :timer.minutes(5)

  def create(conn, params) do
    app = conn.assigns[:service_app]

    cond do
      app == nil ->
        openai_error(conn, 401, "This endpoint needs an app- API token.", "invalid_request_error")

      Chat.quota_exceeded?(app) ->
        openai_error(conn, 429, "The app's daily token limit is spent.", "rate_limit_error")

      true ->
        with {:ok, messages} <- normalize_messages(params["messages"]),
             :ok <- guard_input(app, messages) do
          respond(conn, app, messages, params["stream"] == true)
        else
          {:error, :bad_messages} ->
            openai_error(
              conn,
              400,
              "messages must be a non-empty array.",
              "invalid_request_error"
            )

          {:error, :guardrail} ->
            openai_error(conn, 400, "This content isn't allowed here.", "invalid_request_error")
        end
    end
  end

  # Chatflow apps bridge through their flux; direct-model apps call the
  # provider — same OpenAI contract either way.
  defp completion_fun(%{mode: :advanced_chat}),
    do: &Chat.stateless_chatflow_completion/3

  defp completion_fun(_direct_model), do: &Chat.stateless_completion/3

  ## Blocking

  defp respond(conn, app, messages, false) do
    case completion_fun(app).(app, messages, fn _chunk -> :ok end) do
      {:ok, result, model_used} ->
        json(conn, %{
          "id" => completion_id(),
          "object" => "chat.completion",
          "created" => System.system_time(:second),
          "model" => model_used,
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => result.content},
              "finish_reason" => "stop"
            }
          ],
          "usage" => usage(result)
        })

      {:error, reason} ->
        openai_error(conn, 502, "The model errored: #{inspect(reason)}", "api_error")
    end
  end

  ## Streaming

  defp respond(conn, app, messages, true) do
    parent = self()
    id = completion_id()
    created = System.system_time(:second)

    Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
      emit = fn %{delta: delta} -> send(parent, {:delta, delta}) end

      case completion_fun(app).(app, messages, emit) do
        {:ok, result, model_used} -> send(parent, {:finished, result, model_used})
        {:error, reason} -> send(parent, {:failed, reason})
      end
    end)

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> stream_loop(id, created, app.model)
  end

  defp stream_loop(conn, id, created, model) do
    receive do
      {:delta, delta} ->
        case sse(conn, chunk_frame(id, created, model, %{"content" => delta}, nil)) do
          {:ok, conn} -> stream_loop(conn, id, created, model)
          {:error, _closed} -> conn
        end

      {:finished, result, model_used} ->
        {_, conn} = sse(conn, chunk_frame(id, created, model_used, %{}, "stop", usage(result)))
        {_, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {:failed, reason} ->
        {_, conn} =
          sse(conn, %{
            "error" => %{
              "message" => "The model errored: #{inspect(reason)}",
              "type" => "api_error"
            }
          })

        conn
    after
      @stream_timeout ->
        {_, conn} = chunk(conn, "data: [DONE]\n\n")
        conn
    end
  end

  defp chunk_frame(id, created, model, delta, finish_reason, usage \\ nil) do
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
    |> then(fn frame -> (usage && Map.put(frame, "usage", usage)) || frame end)
  end

  defp sse(conn, payload), do: chunk(conn, "data: " <> Jason.encode!(payload) <> "\n\n")

  ## Request plumbing

  defp normalize_messages(messages) when is_list(messages) and messages != [] do
    normalized =
      for %{"role" => role, "content" => content} <- messages,
          role in ["system", "user", "assistant"],
          text = content_text(content),
          is_binary(text) do
        %{role: String.to_existing_atom(role), content: text}
      end

    if normalized == [], do: {:error, :bad_messages}, else: {:ok, normalized}
  end

  defp normalize_messages(_other), do: {:error, :bad_messages}

  # Content is a string, or OpenAI content-part arrays (text parts kept).
  defp content_text(content) when is_binary(content), do: content

  defp content_text(parts) when is_list(parts) do
    parts
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
    input = get_in_usage(result, :input_tokens)
    output = get_in_usage(result, :output_tokens)

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp get_in_usage(%{usage: usage}, key) when is_map(usage),
    do: Map.get(usage, key) || Map.get(usage, to_string(key)) || 0

  defp get_in_usage(_result, _key), do: 0

  defp completion_id do
    "chatcmpl-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp openai_error(conn, status, message, type) do
    conn
    |> put_status(status)
    |> json(%{"error" => %{"message" => message, "type" => type, "code" => nil}})
  end
end
