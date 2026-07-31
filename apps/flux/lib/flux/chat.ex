defmodule Flux.Chat do
  @moduledoc """
  Chat apps, conversations, and streaming generation.

  Generation runs in a supervised task registered by assistant-message id;
  chunks broadcast on `"message:{id}"` (`{:chunk, delta}` then
  `{:done, message}` / `{:error, message}`), so SSE controllers and
  LiveViews are plain PubSub subscribers and disconnects never kill a run.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.Chat.{ApiToken, App, Conversation, Message}
  alias Flux.Providers
  alias Flux.RBAC
  alias Flux.Repo

  defp runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  ## Apps

  def list_apps(%Scope{} = scope) do
    App |> Repo.scoped(scope) |> order_by([a], desc: a.inserted_at) |> Repo.all()
  end

  def get_app(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(App, id: ^id), scope)) || {:error, :not_found}
  end

  def create_app(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management) do
      %App{workspace_id: Scope.workspace_id(scope), created_by_id: Scope.account_id(scope)}
      |> App.changeset(attrs)
      |> Repo.insert()
    end
  end

  def delete_app(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      Repo.delete(app)
    end
  end

  ## Conversations & messages

  def create_conversation(%Scope{} = scope, %App{} = app, attrs \\ %{}) do
    Repo.insert!(%Conversation{
      workspace_id: Scope.workspace_id(scope),
      app_id: app.id,
      title: Map.get(attrs, :title),
      end_user_ref: Map.get(attrs, :end_user_ref)
    })
  end

  def get_conversation(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Conversation, id: ^id), scope)) || {:error, :not_found}
  end

  def list_conversations(%Scope{} = scope, app_id, limit \\ 20) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id)
    |> order_by([c], desc: c.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def rename_conversation(%Scope{} = scope, conversation_id, name) when is_binary(name) do
    case Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) do
      nil -> {:error, :not_found}
      conversation -> conversation |> Ecto.Changeset.change(title: name) |> Repo.update()
    end
  end

  def delete_conversation(%Scope{} = scope, conversation_id) do
    case Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) do
      nil -> {:error, :not_found}
      conversation -> Repo.delete(conversation)
    end
  end

  @doc "Records end-user feedback (like/dislike/nil to clear) on a message."
  def set_feedback(%Scope{} = scope, message_id, rating) when rating in [:like, :dislike, nil] do
    case Repo.one(Repo.scoped(where(Message, id: ^message_id), scope)) do
      nil -> {:error, :not_found}
      message -> message |> Ecto.Changeset.change(feedback: rating) |> Repo.update()
    end
  end

  def list_messages(%Scope{} = scope, conversation_id) do
    Message
    |> Repo.scoped(scope)
    |> where([m], m.conversation_id == ^conversation_id)
    |> order_by([m], asc: m.inserted_at, asc: m.id)
    |> Repo.all()
  end

  @doc """
  Persists the user message, creates a streaming assistant placeholder,
  subscribes the calling process to the message topic (so no chunk can be
  missed), and starts generation. Returns
  `{:ok, user_message, assistant_message}`.
  """
  def send_message(%Scope{} = scope, %App{} = app, %Conversation{} = conversation, content)
      when is_binary(content) do
    workspace_id = Scope.workspace_id(scope)

    user_message =
      Repo.insert!(%Message{
        workspace_id: workspace_id,
        conversation_id: conversation.id,
        role: :user,
        content: content
      })

    assistant_message =
      Repo.insert!(%Message{
        workspace_id: workspace_id,
        conversation_id: conversation.id,
        role: :assistant,
        status: :streaming
      })

    :ok = subscribe(assistant_message.id)

    history = list_messages(scope, conversation.id)

    {:ok, _pid} =
      Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
        Registry.register(Flux.GenerationRegistry, assistant_message.id, nil)
        generate(app, history, assistant_message)
      end)

    {:ok, user_message, assistant_message}
  end

  @doc """
  Runs a completion app: renders the prompt template with `inputs`
  (referenced as `{{inputs.name}}`), then streams through the normal
  generation pipeline in a fresh conversation.
  """
  def send_completion(scope, app, inputs, attrs \\ %{})

  def send_completion(%Scope{} = scope, %App{mode: :completion} = app, inputs, attrs)
      when is_map(inputs) do
    rendered = Flux.Engine.Template.render(app.prompt_template || "", %{"inputs" => inputs})
    conversation = create_conversation(scope, app, attrs)

    with {:ok, user_message, assistant_message} <-
           send_message(scope, app, conversation, rendered) do
      {:ok, conversation, user_message, assistant_message}
    end
  end

  def send_completion(%Scope{}, %App{}, _inputs, _attrs), do: {:error, :not_completion_app}

  @max_upload_bytes 15 * 1024 * 1024

  @doc "Stores an uploaded file via Flux.Storage and records it."
  def create_upload(%Scope{} = scope, %App{} = app, %{path: path, filename: filename} = upload) do
    with {:ok, binary} <- File.read(path),
         :ok <- check_size(byte_size(binary)) do
      safe_name = filename |> Path.basename() |> String.replace(~r/[^\w\.\-]/, "_")
      key = "uploads/#{Scope.workspace_id(scope)}/#{Ecto.UUID.generate()}-#{safe_name}"

      with :ok <- Flux.Storage.put(key, binary) do
        {:ok,
         Repo.insert!(%Flux.Chat.UploadedFile{
           workspace_id: Scope.workspace_id(scope),
           app_id: app.id,
           name: filename,
           key: key,
           size: byte_size(binary),
           content_type: Map.get(upload, :content_type),
           end_user_ref: Map.get(upload, :end_user_ref)
         })}
      end
    end
  end

  defp check_size(bytes) when bytes <= @max_upload_bytes, do: :ok
  defp check_size(_bytes), do: {:error, :too_large}

  @doc "PubSub topic carrying a message's generation events."
  def topic(message_id), do: "message:#{message_id}"

  def subscribe(message_id), do: Phoenix.PubSub.subscribe(Flux.PubSub, topic(message_id))

  @doc "Stops an in-flight generation; the message is marked `:stopped`."
  def stop_generation(%Scope{} = scope, message_id) do
    case Repo.one(Repo.scoped(where(Message, id: ^message_id), scope)) do
      %Message{status: :streaming} = message ->
        case Registry.lookup(Flux.GenerationRegistry, message_id) do
          [{pid, _}] -> Process.exit(pid, :kill)
          [] -> :ok
        end

        finalize(message, :stopped, current_broadcast_content(message), %{})

      _ ->
        {:error, :not_streaming}
    end
  end

  ## API tokens

  def create_api_token(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management) do
      raw = "app-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      token =
        Repo.insert!(%ApiToken{
          workspace_id: Scope.workspace_id(scope),
          app_id: app.id,
          token_hash: :crypto.hash(:sha256, raw),
          prefix: String.slice(raw, 0, 12) <> "…"
        })

      {:ok, token, raw}
    end
  end

  def list_api_tokens(%Scope{} = scope, app_id) do
    ApiToken |> Repo.scoped(scope) |> where([t], t.app_id == ^app_id) |> Repo.all()
  end

  def revoke_api_token(%Scope{} = scope, token_id) do
    case Repo.one(Repo.scoped(where(ApiToken, id: ^token_id), scope)) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  @doc "Resolves a raw bearer token to `{app, token}`; touches last_used_at."
  def fetch_app_by_token("app-" <> _ = raw) do
    hash = :crypto.hash(:sha256, raw)

    # Token possession is the authorization; the lookup is cross-workspace.
    case Repo.get_by(ApiToken, [token_hash: hash], skip_workspace_guard: true) do
      nil ->
        {:error, :invalid_token}

      token ->
        token
        |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
        |> Repo.update()

        {:ok, Repo.get!(App, token.app_id, skip_workspace_guard: true), token}
    end
  end

  def fetch_app_by_token(_other), do: {:error, :invalid_token}

  ## Generation internals

  defp generate(app, history, assistant_message) do
    request = %Flux.Plugin.ModelProvider.Request{
      model: app.model,
      messages: build_prompt(app, history),
      params: atomize_params(app.params)
    }

    emit = fn %{delta: delta} ->
      Flux.StreamBuffers.append(assistant_message.id, delta)
      Phoenix.PubSub.broadcast(Flux.PubSub, topic(assistant_message.id), {:chunk, delta})
    end

    credentials =
      case Providers.fetch_config(app.workspace_id, app.provider_plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    case runtime().invoke_llm(app.provider_plugin_id, credentials, request, emit) do
      {:ok, result} ->
        finalize(assistant_message, :completed, result.content, %{
          "input_tokens" => result.usage.input_tokens,
          "output_tokens" => result.usage.output_tokens
        })

      {:error, reason} ->
        Flux.StreamBuffers.delete(assistant_message.id)

        message =
          assistant_message
          |> Ecto.Changeset.change(status: :error, error: format_error(reason))
          |> Repo.update!()

        Phoenix.PubSub.broadcast(Flux.PubSub, topic(assistant_message.id), {:error, message})
        {:error, reason}
    end
  end

  defp finalize(message, status, content, usage) do
    Flux.StreamBuffers.delete(message.id)

    message =
      message
      |> Ecto.Changeset.change(status: status, content: content, usage: usage)
      |> Repo.update!()

    Phoenix.PubSub.broadcast(Flux.PubSub, topic(message.id), {:done, message})
    {:ok, message}
  end

  defp build_prompt(app, history) do
    system =
      case app.system_prompt do
        prompt when is_binary(prompt) and prompt != "" -> [%{role: :system, content: prompt}]
        _ -> []
      end

    turns =
      history
      |> Enum.filter(&(&1.status == :completed or &1.role == :user))
      |> Enum.map(&%{role: &1.role, content: &1.content})

    system ++ turns
  end

  # Stop killed the task mid-stream; the stream buffer holds every delta
  # emitted so far, so the persisted message keeps the streamed prefix.
  defp current_broadcast_content(message), do: Flux.StreamBuffers.get(message.id)

  defp atomize_params(params) do
    for {key, value} <- params, key in ~w(temperature max_tokens top_p), into: %{} do
      {String.to_existing_atom(key), value}
    end
  end

  defp format_error({:invalid_credentials, reason}), do: reason
  defp format_error({:http_error, status, _body}), do: "Provider returned HTTP #{status}."
  defp format_error(:timeout), do: "The model did not respond in time."
  defp format_error(other), do: "Generation failed: #{inspect(other)}"
end
