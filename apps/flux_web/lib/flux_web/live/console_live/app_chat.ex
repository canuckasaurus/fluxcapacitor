defmodule FluxWeb.ConsoleLive.AppChat do
  @moduledoc false
  use FluxWeb, :live_view

  alias Flux.Chat
  alias Flux.Chat.App
  alias Flux.RBAC

  @impl true
  def mount(%{"id" => app_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Chat.get_app(scope, app_id) do
      %App{} = app ->
        # Pick up where you left off: the console resumes your latest
        # conversation, same as the public sites do for visitors.
        conversations =
          if app.mode in [:chat, :advanced_chat] do
            Chat.console_conversations(scope, app.id)
          else
            []
          end

        {conversation, messages} =
          case conversations do
            [latest | _rest] -> {latest, resumable_messages(scope, latest.id)}
            [] -> {nil, []}
          end

        {:ok,
         socket
         |> allow_upload(:image,
           accept: ~w(.png .jpg .jpeg .gif .webp),
           max_entries: 3,
           max_file_size: 15_000_000
         )
         |> allow_upload(:audio,
           accept: ~w(audio/webm audio/ogg audio/mpeg audio/wav video/webm),
           max_entries: 1,
           max_file_size: 20_000_000,
           auto_upload: true,
           progress: &handle_audio_progress/3
         )
         |> assign(
           page_title: app.name,
           app: app,
           conversations: conversations,
           conversation: conversation,
           messages: messages,
           renaming: false,
           followups: [],
           streaming_id: nil,
           streaming_text: "",
           api_tokens: Chat.list_api_tokens(scope, app.id),
           models: Flux.Providers.available_models(scope),
           new_token: nil,
           can_manage: RBAC.can?(scope, :app_create_and_management),
           can_edit: RBAC.can?(scope, :app_edit),
           var_rows: app.input_form,
           template_draft: app.prompt_template,
           transcribing: false
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "App not found.")
         |> push_navigate(to: ~p"/console/apps")}
    end
  end

  # Voice input: the MicRecorder hook uploads the recording; once the
  # entry completes it transcribes through the app's provider and the
  # transcript lands in the input box client-side.
  defp handle_audio_progress(:audio, entry, socket) do
    if entry.done? do
      transcript =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok,
           Chat.transcribe_audio(
             socket.assigns.current_scope,
             socket.assigns.app,
             File.read!(path),
             %{filename: entry.client_name, content_type: entry.client_type}
           )}
        end)

      case transcript do
        {:ok, text} ->
          {:noreply,
           socket
           |> assign(transcribing: false)
           |> push_event("voice-transcript", %{text: text})}

        {:error, :not_supported} ->
          {:noreply,
           socket
           |> assign(transcribing: false)
           |> put_flash(:error, "This app's provider has no transcription endpoint.")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(transcribing: false)
           |> put_flash(:error, "Transcription failed — try again.")}
      end
    else
      {:noreply, assign(socket, transcribing: true)}
    end
  end

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("send", %{"content" => content}, socket) when content != "" do
    scope = socket.assigns.current_scope
    app = socket.assigns.app

    conversation =
      socket.assigns.conversation || Chat.create_conversation(scope, app)

    files =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        Chat.create_upload(scope, app, %{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        })
      end)

    case Chat.send_message(scope, app, conversation, content, files: files) do
      {:ok, user_message, assistant_message} ->
        conversations =
          if socket.assigns.conversation == nil do
            Chat.console_conversations(scope, app.id)
          else
            socket.assigns.conversations
          end

        {:noreply,
         assign(socket,
           conversation: conversation,
           conversations: conversations,
           messages: socket.assigns.messages ++ [user_message],
           followups: [],
           streaming_id: assistant_message.id,
           streaming_text: ""
         )}

      {:error, :guardrail} ->
        {:noreply, put_flash(socket, :error, "That message isn't allowed here.")}

      {:error, :quota_exceeded} ->
        {:noreply,
         put_flash(socket, :error, "This app's daily token limit is spent — try again tomorrow.")}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("suggest", %{"question" => question}, socket) do
    handle_event("send", %{"content" => question}, socket)
  end

  def handle_event("speak_reply", %{"id" => message_id}, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))
    text = (message && message.content) || ""

    case text != "" &&
           Chat.synthesize_speech(socket.assigns.current_scope, socket.assigns.app, text) do
      {:ok, %{audio: audio, content_type: content_type}} ->
        {:noreply,
         push_event(socket, "play-audio", %{
           data: Base.encode64(audio),
           content_type: content_type
         })}

      _fallback ->
        # No provider voice — the browser's speechSynthesis reads it.
        {:noreply, push_event(socket, "speak-fallback", %{text: text})}
    end
  end

  def handle_event("stop", _params, socket) do
    if id = socket.assigns.streaming_id do
      Chat.stop_generation(socket.assigns.current_scope, id)
    end

    {:noreply, socket}
  end

  def handle_event("regenerate", _params, socket) do
    scope = socket.assigns.current_scope

    with %Flux.Chat.Conversation{} = conversation <- socket.assigns.conversation,
         {:ok, assistant_message} <-
           Chat.regenerate(scope, socket.assigns.app, conversation) do
      {:noreply,
       assign(socket,
         messages: drop_last_assistant(socket.assigns.messages),
         streaming_id: assistant_message.id,
         streaming_text: ""
       )}
    else
      {:error, :quota_exceeded} ->
        {:noreply,
         put_flash(socket, :error, "This app's daily token limit is spent — try again tomorrow.")}

      _nothing_to_do ->
        {:noreply, socket}
    end
  end

  def handle_event("new-conversation", _params, socket) do
    {:noreply,
     assign(socket,
       conversation: nil,
       messages: [],
       followups: [],
       streaming_id: nil,
       streaming_text: ""
     )}
  end

  def handle_event("switch_conversation", %{"conversation-id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Enum.find(socket.assigns.conversations, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      conversation ->
        {:noreply,
         assign(socket,
           conversation: conversation,
           messages: resumable_messages(scope, conversation.id),
           followups: [],
           streaming_id: nil,
           streaming_text: "",
           renaming: false
         )}
    end
  end

  def handle_event("search_conversations", %{"q" => q}, socket) do
    scope = socket.assigns.current_scope
    app = socket.assigns.app

    conversations =
      case String.trim(to_string(q)) do
        "" -> Chat.console_conversations(scope, app.id)
        query -> Chat.search_conversations(scope, app.id, query)
      end

    {:noreply, assign(socket, conversations: conversations)}
  end

  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, renaming: not socket.assigns.renaming)}
  end

  def handle_event("rename_conversation", %{"title" => title}, socket) do
    scope = socket.assigns.current_scope

    with %Flux.Chat.Conversation{} = conversation <- socket.assigns.conversation,
         title when title != "" <- String.trim(to_string(title)),
         {:ok, renamed} <- Chat.rename_conversation(scope, conversation.id, title) do
      {:noreply,
       assign(socket,
         conversation: renamed,
         conversations: Chat.console_conversations(scope, socket.assigns.app.id),
         renaming: false
       )}
    else
      _invalid -> {:noreply, assign(socket, renaming: false)}
    end
  end

  def handle_event("delete_conversation", _params, socket) do
    scope = socket.assigns.current_scope

    with %Flux.Chat.Conversation{} = conversation <- socket.assigns.conversation,
         {:ok, _deleted} <- Chat.delete_conversation(scope, conversation.id) do
      conversations = Chat.console_conversations(scope, socket.assigns.app.id)

      {conversation, messages} =
        case conversations do
          [latest | _rest] -> {latest, resumable_messages(scope, latest.id)}
          [] -> {nil, []}
        end

      {:noreply,
       assign(socket,
         conversation: conversation,
         conversations: conversations,
         messages: messages,
         streaming_id: nil,
         streaming_text: ""
       )}
    else
      _nothing -> {:noreply, socket}
    end
  end

  ## Completion apps: run panel + configuration

  def handle_event("run_completion", params, socket) do
    scope = socket.assigns.current_scope

    case Chat.send_completion(scope, socket.assigns.app, params["inputs"] || %{}) do
      {:ok, conversation, _user_message, assistant_message} ->
        {:noreply,
         assign(socket,
           conversation: conversation,
           messages: [],
           streaming_id: assistant_message.id,
           streaming_text: ""
         )}

      {:error, :not_completion_app} ->
        {:noreply, put_flash(socket, :error, "This app is not in completion mode.")}

      {:error, :guardrail} ->
        {:noreply, put_flash(socket, :error, "That message isn't allowed here.")}

      {:error, :quota_exceeded} ->
        {:noreply,
         put_flash(socket, :error, "This app's daily token limit is spent — try again tomorrow.")}
    end
  end

  def handle_event("add_var", _params, socket) do
    {:noreply,
     assign(socket,
       var_rows: socket.assigns.var_rows ++ [%{"type" => "text-input", "required" => false}]
     )}
  end

  def handle_event("remove_var", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       var_rows: List.delete_at(socket.assigns.var_rows, String.to_integer(index))
     )}
  end

  def handle_event("settings_change", params, socket) do
    {:noreply,
     assign(socket, template_draft: params["prompt_template"], var_rows: parse_var_rows(params))}
  end

  def handle_event("save_settings", params, socket) do
    scope = socket.assigns.current_scope

    rows =
      params
      |> parse_var_rows()
      |> Enum.reject(&(&1["variable"] == ""))

    case Chat.update_app(scope, socket.assigns.app, %{
           "prompt_template" => params["prompt_template"],
           "input_form" => rows
         }) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Configuration saved.")
         |> assign(app: app, var_rows: app.input_form, template_draft: app.prompt_template)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this app.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not save the configuration.")}
    end
  end

  def handle_event("enable_site", _params, socket) do
    case Chat.enable_site(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, app} ->
        {:noreply, assign(socket, app: app)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to publish this app.")}
    end
  end

  def handle_event("disable_site", _params, socket) do
    case Chat.disable_site(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, app} ->
        {:noreply, assign(socket, app: app)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to unpublish this app.")}
    end
  end

  def handle_event("save_chat_settings", params, socket) do
    scope = socket.assigns.current_scope

    questions =
      params
      |> Map.get("suggested_questions_text", "")
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {fallback_plugin, fallback_model} =
      case String.split(params["fallback_choice"] || "keep", "|", parts: 2) do
        [plugin, model] ->
          {plugin, model}

        ["keep"] ->
          {socket.assigns.app.fallback_provider_plugin_id, socket.assigns.app.fallback_model}

        _cleared ->
          {nil, nil}
      end

    {ab_plugin, ab_model} =
      case String.split(params["ab_choice"] || "keep", "|", parts: 2) do
        [plugin, model] -> {plugin, model}
        ["keep"] -> {socket.assigns.app.ab_provider_plugin_id, socket.assigns.app.ab_model}
        _cleared -> {nil, nil}
      end

    ab_split =
      case Integer.parse(to_string(params["ab_split"] || "")) do
        {n, ""} when n in 0..100 -> n
        _off -> 0
      end

    case Chat.update_app(scope, socket.assigns.app, %{
           "opening_statement" => params["opening_statement"],
           "suggested_questions" => questions,
           "daily_token_limit" => presence(params["daily_token_limit"]),
           "rate_limit_per_minute" => presence(params["rate_limit_per_minute"]),
           "annotation_threshold" => presence(params["annotation_threshold"]),
           "suggest_followups" => params["suggest_followups"] == "on",
           "fallback_provider_plugin_id" => fallback_plugin,
           "fallback_model" => fallback_model,
           "ab_provider_plugin_id" => ab_plugin,
           "ab_model" => ab_model,
           "ab_split" => (ab_plugin && ab_split) || 0
         }) do
      {:ok, app} ->
        {:noreply, socket |> put_flash(:info, "Chat settings saved.") |> assign(app: app)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this app.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not save the settings.")}
    end
  end

  def handle_event("save_theme", params, socket) do
    theme =
      %{
        "accent" => presence(params["accent"]),
        "title" => presence(params["title"]),
        "logo_url" => presence(params["logo_url"])
      }
      |> Enum.reject(fn {_key, value} -> value == nil end)
      |> Map.new()

    case Chat.update_app(socket.assigns.current_scope, socket.assigns.app, %{
           "site_theme" => theme
         }) do
      {:ok, app} ->
        {:noreply, socket |> put_flash(:info, "Site theme saved.") |> assign(app: app)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the theme.")}
    end
  end

  def handle_event("create-token", params, socket) do
    expires_in_days =
      case Integer.parse(to_string(params["lifetime"] || "")) do
        {days, ""} when days > 0 -> days
        _perpetual -> nil
      end

    case Chat.create_api_token(socket.assigns.current_scope, socket.assigns.app,
           expires_in_days: expires_in_days
         ) do
      {:ok, _token, raw} ->
        {:noreply,
         assign(socket,
           new_token: raw,
           api_tokens: Chat.list_api_tokens(socket.assigns.current_scope, socket.assigns.app.id)
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage API keys.")}
    end
  end

  def handle_event("revoke-token", %{"token-id" => id}, socket) do
    Chat.revoke_api_token(socket.assigns.current_scope, id)

    {:noreply,
     assign(socket,
       api_tokens: Chat.list_api_tokens(socket.assigns.current_scope, socket.assigns.app.id)
     )}
  end

  @impl true
  def handle_info({:chunk, delta}, socket) do
    {:noreply, assign(socket, streaming_text: socket.assigns.streaming_text <> delta)}
  end

  def handle_info({:done, message}, socket) do
    followups =
      with true <- socket.assigns.app.suggest_followups,
           %Flux.Chat.Conversation{} = conversation <- socket.assigns.conversation do
        Chat.follow_up_suggestions(
          socket.assigns.current_scope,
          socket.assigns.app,
          conversation.id
        )
      else
        _off -> []
      end

    # Chatflows may have written conversation variables during the turn.
    conversation =
      case socket.assigns.conversation do
        %Flux.Chat.Conversation{} = conversation ->
          case Chat.get_conversation(socket.assigns.current_scope, conversation.id) do
            %Flux.Chat.Conversation{} = fresh -> fresh
            _gone -> conversation
          end

        nil ->
          nil
      end

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [message],
       followups: followups,
       conversation: conversation,
       streaming_id: nil,
       streaming_text: ""
     )}
  end

  def handle_info({:error, message}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, message.error || "Generation failed.")
     |> assign(
       messages: socket.assigns.messages ++ [message],
       streaming_id: nil,
       streaming_text: ""
     )}
  end

  defp presence(nil), do: nil
  defp presence(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  # Streaming placeholders don't resume; finished turns do.
  defp resumable_messages(scope, conversation_id) do
    scope
    |> Chat.list_messages(conversation_id)
    |> Enum.filter(&(&1.status in [:completed, :error] or &1.role == :user))
  end

  defp last_assistant_id(messages) do
    case List.last(messages) do
      %{role: :assistant, status: status, id: id} when status != :error -> id
      _other -> nil
    end
  end

  defp drop_last_assistant(messages) do
    case List.last(messages) do
      %{role: :assistant} -> Enum.drop(messages, -1)
      _other -> messages
    end
  end

  defp parse_var_rows(%{"vars" => vars}) when is_map(vars) do
    vars
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} ->
      %{
        "variable" => String.trim(row["variable"] || ""),
        "label" => row["label"] || "",
        "type" => row["type"] || "text-input",
        "required" => row["required"] == "true"
      }
    end)
  end

  defp parse_var_rows(_params), do: []

  defp embed_snippet(app) do
    ~s(<iframe src="#{url(~p"/site/#{app.site_token}")}"\n  style="width: 100%; height: 640px; border: 0; border-radius: 12px;"\n  allow="clipboard-write"></iframe>)
  end

  defp bubble_snippet(site_token) do
    ~s(<script src="#{url(~p"/embed.js")}"\n  data-flux-site="#{url(~p"/site/#{site_token}")}" defer></script>)
  end

  defp completion_output(messages) do
    case List.last(messages) do
      %{role: :assistant, status: :error, error: error} -> error
      %{role: :assistant, content: content} -> content
      _no_output_yet -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:apps}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{@app.name}</h1>
          <p class="opacity-60 text-sm">{@app.provider_plugin_id} · {@app.model}</p>
        </div>
        <div class="flex gap-2 items-center">
          <form
            :if={@app.mode in [:chat, :advanced_chat]}
            phx-change="search_conversations"
            id="conversation-search"
          >
            <input
              type="search"
              name="q"
              placeholder="Search threads…"
              class="input input-bordered input-sm w-36"
              phx-debounce="300"
              aria-label="Search conversations"
            />
          </form>
          <form
            :if={@app.mode in [:chat, :advanced_chat] and @conversations != []}
            phx-change="switch_conversation"
            id="conversation-switcher"
          >
            <select
              name="conversation-id"
              class="select select-bordered select-sm max-w-44"
              aria-label="Switch conversation"
            >
              <option value="" selected={@conversation == nil} disabled hidden>
                Conversations…
              </option>
              <option
                :for={conversation <- @conversations}
                value={conversation.id}
                selected={@conversation != nil and @conversation.id == conversation.id}
              >
                {conversation.title ||
                  Calendar.strftime(conversation.inserted_at, "%b %d %H:%M")}
              </option>
            </select>
          </form>
          <button
            :if={@app.mode in [:chat, :advanced_chat] and @conversation != nil}
            class="btn btn-sm btn-ghost btn-square"
            phx-click="start_rename"
            title="Rename this conversation"
            aria-label="Rename this conversation"
          >
            <.icon name="hero-pencil" class="size-4" />
          </button>
          <button
            :if={@app.mode in [:chat, :advanced_chat] and @conversation != nil}
            class="btn btn-sm btn-ghost btn-square text-error"
            phx-click="delete_conversation"
            data-confirm="Delete this conversation and its messages?"
            title="Delete this conversation"
            aria-label="Delete this conversation"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
          <.link
            :if={@app.mode in [:chat, :advanced_chat] and @conversation != nil}
            href={~p"/console/apps/#{@app.id}/conversations/#{@conversation.id}/export"}
            class="btn btn-sm btn-ghost btn-square"
            title="Download this conversation as Markdown (add ?format=json for JSON)"
            aria-label="Download this conversation"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
          </.link>
          <button
            :if={@app.mode in [:chat, :advanced_chat]}
            class="btn btn-sm btn-ghost"
            phx-click="new-conversation"
          >
            New conversation
          </button>
          <.link
            :if={Flux.RBAC.can?(@current_scope, :app_import_export_dsl)}
            href={~p"/console/apps/#{@app.id}/export"}
            class="btn btn-sm btn-ghost"
            title="Download portable DSL"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Export
          </.link>
          <.link
            :if={Flux.RBAC.can?(@current_scope, :app_monitor)}
            navigate={~p"/console/apps/#{@app.id}/monitor"}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-chart-bar" class="size-4" /> Monitor
          </.link>
          <.link navigate={~p"/console/apps"} class="btn btn-sm btn-ghost">&larr; All apps</.link>
        </div>
      </div>

      <form
        :if={@renaming and @conversation != nil}
        phx-submit="rename_conversation"
        class="flex gap-2 items-center justify-end"
        id="rename-form"
      >
        <input
          type="text"
          name="title"
          value={@conversation.title}
          placeholder="Conversation title"
          class="input input-sm input-bordered max-w-60"
          autofocus
        />
        <button class="btn btn-sm btn-primary">Rename</button>
        <button type="button" class="btn btn-sm btn-ghost" phx-click="start_rename">Cancel</button>
      </form>

      <details
        :if={@conversation != nil and (@conversation.variables || %{}) != %{}}
        class="text-xs"
        id="conversation-variables"
      >
        <summary class="cursor-pointer opacity-70">
          Conversation variables ({map_size(@conversation.variables)})
        </summary>
        <div class="mt-1 rounded-box bg-base-200 p-2 space-y-1">
          <p :for={{name, value} <- Enum.sort(@conversation.variables)} class="font-mono">
            <span class="font-semibold">{name}</span>
            = {(is_binary(value) && value) || Jason.encode!(value)}
          </p>
        </div>
      </details>

      <div
        :if={@app.mode in [:chat, :advanced_chat]}
        class="card border border-base-200 p-6 space-y-4"
      >
        <div id="chat-messages" class="space-y-3 max-h-[28rem] overflow-y-auto">
          <p :if={@messages == [] and @streaming_id == nil} class="text-sm opacity-60">
            Say something to start the conversation.
          </p>
          <div
            :for={message <- @messages}
            class={["chat", (message.role == :user && "chat-end") || "chat-start"]}
            id={"message-#{message.id}"}
          >
            <div class={[
              "chat-bubble",
              message.role == :user && "chat-bubble-primary",
              message.status == :error && "chat-bubble-error"
            ]}>
              <%= cond do %>
                <% message.status == :error -> %>
                  <span class="whitespace-pre-wrap">{message.error}</span>
                <% message.role == :assistant -> %>
                  <div class="markdown-chat">{FluxWeb.Markdown.render(message.content)}</div>
                <% true -> %>
                  <span class="whitespace-pre-wrap">{message.content}</span>
              <% end %>
            </div>
            <div
              :if={message.role == :assistant and message.status == :completed}
              class="chat-footer mt-1 flex gap-1"
            >
              <button
                type="button"
                class="btn btn-ghost btn-xs copy-reply"
                title="Copy this reply"
                aria-label="Copy this reply"
              >
                <.icon name="hero-clipboard" class="size-3" /> Copy
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="speak_reply"
                phx-value-id={message.id}
                title="Read this reply aloud (provider voice, browser fallback)"
                aria-label="Read this reply aloud"
              >
                <.icon name="hero-speaker-wave" class="size-3" /> Listen
              </button>
              <button
                :if={@streaming_id == nil and message.id == last_assistant_id(@messages)}
                class="btn btn-ghost btn-xs"
                phx-click="regenerate"
                title="Regenerate this reply"
                aria-label="Regenerate this reply"
              >
                <.icon name="hero-arrow-path" class="size-3" /> Regenerate
              </button>
            </div>
            <div
              :if={message.role == :user and (message.files || []) != []}
              class="chat-footer mt-1 flex flex-wrap gap-1"
            >
              <span :for={file <- message.files} class="badge badge-outline badge-sm gap-1">
                <.icon name="hero-photo" class="size-3" /> {file["name"]}
              </span>
            </div>
            <div
              :if={message.role == :assistant and (message.usage["files"] || []) != []}
              class="chat-footer mt-1 flex flex-wrap gap-1"
            >
              <a
                :for={file <- message.usage["files"]}
                href={file["url"]}
                target="_blank"
                class="btn btn-outline btn-xs"
                title="Download the generated document"
              >
                <.icon name="hero-document-arrow-down" class="size-3" /> {file["name"]}
              </a>
            </div>
            <div
              :if={message.role == :assistant and message.citations != []}
              class="chat-footer opacity-60 text-xs mt-0.5"
            >
              <.icon name="hero-book-open-micro" class="size-3 inline" /> Sources:
              <span :for={citation <- Enum.uniq_by(message.citations, & &1["document"])}>
                <%= if citation["dataset_id"] && citation["document_id"] do %>
                  <.link
                    navigate={
                      ~p"/console/knowledge?dataset=#{citation["dataset_id"]}&document=#{citation["document_id"]}"
                    }
                    class="link"
                  >
                    {citation["document"]}
                  </.link>
                <% else %>
                  {citation["document"]}
                <% end %>
              </span>
            </div>
          </div>
          <div :if={@streaming_id} class="chat chat-start" id="streaming-bubble">
            <div class="chat-bubble">
              <div class="markdown-chat">{FluxWeb.Markdown.render(@streaming_text)}</div>
              <span class="animate-pulse">▌</span>
            </div>
          </div>
          <div
            :if={@followups != [] and @streaming_id == nil}
            class="flex flex-wrap gap-2"
            id="followup-chips"
          >
            <button
              :for={question <- @followups}
              class="btn btn-outline btn-xs"
              phx-click="suggest"
              phx-value-question={question}
            >
              {question}
            </button>
          </div>
        </div>

        <form phx-submit="send" phx-change="validate_upload" class="space-y-2" id="chat-form">
          <div :if={@uploads.image.entries != []} class="flex flex-wrap gap-2">
            <span
              :for={entry <- @uploads.image.entries}
              class="badge badge-outline gap-1"
            >
              <.icon name="hero-photo" class="size-3" />
              {entry.client_name}
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                aria-label="Remove attachment"
                class="text-error"
              >
                ✕
              </button>
            </span>
          </div>
          <div class="flex gap-2 items-center">
            <label
              class="btn btn-ghost btn-sm btn-square"
              title="Attach images (vision models)"
              aria-label="Attach images"
            >
              <.live_file_input upload={@uploads.image} class="hidden" />
              <.icon name="hero-paper-clip" class="size-4" />
            </label>
            <.live_file_input upload={@uploads.audio} class="hidden" />
            <button
              type="button"
              id="mic-button"
              phx-hook="MicRecorder"
              data-upload-name="audio"
              class="btn btn-ghost btn-sm btn-square"
              title="Hold to talk — release to transcribe"
              aria-label="Voice input"
            >
              <.icon name="hero-microphone" class="size-4" />
            </button>
            <input
              type="text"
              name="content"
              id="chat-content-input"
              autocomplete="off"
              placeholder={(@transcribing && "Transcribing…") || "Type a message…"}
              class="input input-bordered flex-1"
              disabled={@streaming_id != nil}
            />
            <button :if={@streaming_id == nil} class="btn btn-primary">Send</button>
            <button :if={@streaming_id} type="button" class="btn btn-warning" phx-click="stop">
              Stop
            </button>
          </div>
        </form>
      </div>

      <div
        :if={@app.mode in [:chat, :advanced_chat] and @can_edit}
        class="card border border-base-200 p-6 space-y-3"
      >
        <h2 class="font-semibold">Chat settings</h2>
        <form id="chat-settings-form" phx-submit="save_chat_settings" class="space-y-3">
          <label class="form-control block">
            <span class="label-text text-sm mb-1">
              Opening statement (shown before the first message)
            </span>
            <textarea
              name="opening_statement"
              rows="2"
              class="textarea textarea-bordered w-full"
            >{@app.opening_statement}</textarea>
          </label>
          <label class="form-control block">
            <span class="label-text text-sm mb-1">Suggested questions (one per line)</span>
            <textarea
              name="suggested_questions_text"
              rows="3"
              class="textarea textarea-bordered w-full"
            >{Enum.join(@app.suggested_questions, "\n")}</textarea>
          </label>
          <label class="form-control block">
            <span class="label-text text-sm mb-1">
              Daily token limit (blank = unlimited; refusals return 429 on the API)
            </span>
            <input
              type="number"
              name="daily_token_limit"
              value={@app.daily_token_limit}
              min="1"
              class="input input-bordered input-sm w-48"
            />
          </label>
          <label class="form-control block">
            <span class="label-text text-sm mb-1">
              API rate limit (requests/minute for this app's tokens; blank = pipeline default 120)
            </span>
            <input
              type="number"
              name="rate_limit_per_minute"
              value={@app.rate_limit_per_minute}
              min="1"
              max="10000"
              class="input input-bordered input-sm w-48"
            />
          </label>
          <label class="form-control block">
            <span class="label-text text-sm mb-1">
              Annotation similarity threshold (0–1, blank = exact matches only)
            </span>
            <input
              type="number"
              name="annotation_threshold"
              value={@app.annotation_threshold}
              min="0"
              max="1"
              step="0.01"
              placeholder="exact only"
              class="input input-bordered input-sm w-48"
            />
          </label>
          <label class="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              name="suggest_followups"
              class="checkbox checkbox-sm"
              checked={@app.suggest_followups}
            /> Suggest follow-up questions after each reply (one extra model call per turn)
          </label>
          <label :if={@app.mode == :chat} class="form-control block">
            <span class="label-text text-sm mb-1">
              Fallback model (one retry when the primary provider errors)
            </span>
            <select name="fallback_choice" class="select select-bordered select-sm w-full max-w-md">
              <option value="" selected={@app.fallback_model in [nil, ""]}>No fallback</option>
              <option
                :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
                value={"#{pid}|#{m.name}"}
                selected={@app.fallback_provider_plugin_id == pid and @app.fallback_model == m.name}
              >
                {pname} — {m.label}
              </option>
            </select>
          </label>
          <div :if={@app.mode == :chat} class="flex flex-wrap gap-2 items-end">
            <label class="form-control block">
              <span class="label-text text-sm mb-1">
                A/B challenger model (splits conversations against the primary)
              </span>
              <select name="ab_choice" class="select select-bordered select-sm w-full max-w-md">
                <option value="" selected={@app.ab_model in [nil, ""]}>No A/B test</option>
                <option
                  :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
                  value={"#{pid}|#{m.name}"}
                  selected={@app.ab_provider_plugin_id == pid and @app.ab_model == m.name}
                >
                  {pname} — {m.label}
                </option>
              </select>
            </label>
            <label class="form-control block">
              <span class="label-text text-sm mb-1">% of conversations</span>
              <input
                type="number"
                name="ab_split"
                value={@app.ab_split}
                min="0"
                max="100"
                class="input input-bordered input-sm w-24"
              />
            </label>
          </div>
          <button class="btn btn-primary btn-sm">Save chat settings</button>
        </form>
      </div>

      <div :if={@app.mode == :completion} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Run</h2>
        <form phx-submit="run_completion" id="completion-form" class="space-y-3">
          <p :if={@app.input_form == []} class="text-sm opacity-60">
            No form variables defined — the prompt template runs as-is.
          </p>
          <div :for={field <- @app.input_form} class="form-control">
            <label class="label-text text-sm mb-1">
              {(field["label"] != "" && field["label"]) || field["variable"]}
              <span :if={field["required"]} class="text-error">*</span>
            </label>
            <textarea
              :if={field["type"] == "paragraph"}
              name={"inputs[#{field["variable"]}]"}
              rows="3"
              required={field["required"] == true}
              class="textarea textarea-bordered w-full"
            ></textarea>
            <input
              :if={field["type"] == "number"}
              type="number"
              name={"inputs[#{field["variable"]}]"}
              required={field["required"] == true}
              class="input input-bordered w-full"
            />
            <input
              :if={field["type"] not in ["paragraph", "number"]}
              type="text"
              name={"inputs[#{field["variable"]}]"}
              required={field["required"] == true}
              class="input input-bordered w-full"
            />
          </div>
          <div class="flex gap-2">
            <button :if={@streaming_id == nil} class="btn btn-primary btn-sm">
              <.icon name="hero-play" class="size-4" /> Run
            </button>
            <button :if={@streaming_id} type="button" class="btn btn-warning btn-sm" phx-click="stop">
              Stop
            </button>
          </div>
        </form>

        <div
          :if={@streaming_id != nil or completion_output(@messages) != nil}
          id="completion-output"
          class="rounded-box bg-base-200 p-4 text-sm whitespace-pre-wrap"
        >
          {(@streaming_id && @streaming_text) || completion_output(@messages)}
          <span :if={@streaming_id} class="animate-pulse">▌</span>
        </div>
      </div>

      <div
        :if={@app.mode == :completion and @can_edit}
        class="card border border-base-200 p-6 space-y-3"
      >
        <h2 class="font-semibold">Configuration</h2>
        <form
          id="settings-form"
          phx-submit="save_settings"
          phx-change="settings_change"
          class="space-y-3"
        >
          <label class="form-control block">
            <span class="label-text text-sm mb-1">
              Prompt template — reference variables as <code>{"{{inputs.name}}"}</code>
            </span>
            <textarea
              name="prompt_template"
              rows="3"
              placeholder="Summarize the following text: {{inputs.text}}"
              class="textarea textarea-bordered w-full font-mono"
            >{@template_draft}</textarea>
          </label>

          <p class="text-sm font-semibold">Form variables</p>
          <div
            :for={{row, index} <- Enum.with_index(@var_rows)}
            class="flex items-center gap-2 flex-wrap"
            id={"var-row-#{index}"}
          >
            <input
              type="text"
              name={"vars[#{index}][variable]"}
              value={row["variable"]}
              placeholder="variable"
              class="input input-bordered input-sm font-mono w-36"
            />
            <input
              type="text"
              name={"vars[#{index}][label]"}
              value={row["label"]}
              placeholder="Label"
              class="input input-bordered input-sm flex-1 min-w-32"
            />
            <select name={"vars[#{index}][type]"} class="select select-bordered select-sm w-32">
              <option value="text-input" selected={row["type"] in [nil, "", "text-input"]}>
                Text
              </option>
              <option value="paragraph" selected={row["type"] == "paragraph"}>Paragraph</option>
              <option value="number" selected={row["type"] == "number"}>Number</option>
            </select>
            <label class="flex items-center gap-1 text-xs">
              <input type="hidden" name={"vars[#{index}][required]"} value="false" />
              <input
                type="checkbox"
                name={"vars[#{index}][required]"}
                value="true"
                checked={row["required"] == true}
                class="checkbox checkbox-xs"
              /> required
            </label>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              phx-click="remove_var"
              phx-value-index={index}
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>

          <div class="flex gap-2">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="add_var">
              <.icon name="hero-plus" class="size-4" /> Add variable
            </button>
            <button type="submit" class="btn btn-primary btn-sm">Save configuration</button>
          </div>
        </form>
      </div>

      <div :if={@can_manage} class="card border border-base-200 p-6 space-y-3" id="site-publishing">
        <div class="flex items-center justify-between">
          <h2 class="font-semibold">Site publishing</h2>
          <button
            :if={not @app.site_enabled}
            class="btn btn-sm btn-primary"
            phx-click="enable_site"
          >
            <.icon name="hero-globe-alt" class="size-4" /> Publish site
          </button>
          <button
            :if={@app.site_enabled}
            class="btn btn-sm btn-ghost text-error"
            phx-click="disable_site"
            data-confirm="Unpublish the public site?"
          >
            Unpublish
          </button>
        </div>
        <p :if={not @app.site_enabled} class="text-sm opacity-60">
          Publish this app at a public URL anyone can use — no login required.
        </p>
        <div :if={@app.site_enabled} class="space-y-2">
          <p class="text-sm">
            Live at
            <a
              href={url(~p"/site/#{@app.site_token}")}
              target="_blank"
              class="link link-primary font-mono text-xs"
            >
              {url(~p"/site/#{@app.site_token}")}
            </a>
          </p>
          <p class="text-xs opacity-60">Embed it on any page:</p>
          <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{embed_snippet(@app)}</pre>
          <p class="text-xs opacity-60">Or as a floating chat bubble:</p>
          <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{bubble_snippet(@app.site_token)}</pre>
          <form
            phx-submit="save_theme"
            id="site-theme-form"
            class="flex items-end gap-2 flex-wrap border-t border-base-200 pt-3"
          >
            <label class="form-control">
              <span class="label-text text-xs opacity-70 mb-1">Accent</span>
              <input
                type="color"
                name="accent"
                value={@app.site_theme["accent"] || "#6d28d9"}
                class="h-8 w-14 cursor-pointer rounded border border-base-300"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs opacity-70 mb-1">Title override</span>
              <input
                type="text"
                name="title"
                value={@app.site_theme["title"]}
                placeholder={@app.name}
                class="input input-bordered input-sm w-44"
              />
            </label>
            <label class="form-control flex-1 min-w-48">
              <span class="label-text text-xs opacity-70 mb-1">Logo URL (optional)</span>
              <input
                type="url"
                name="logo_url"
                value={@app.site_theme["logo_url"]}
                placeholder="https://…/logo.png"
                class="input input-bordered input-sm w-full"
              />
            </label>
            <button class="btn btn-primary btn-sm">Save theme</button>
          </form>
        </div>
      </div>

      <div :if={@can_manage} class="card border border-base-200 p-6 space-y-3">
        <div class="flex items-center justify-between gap-2">
          <h2 class="font-semibold">API keys</h2>
          <form phx-submit="create-token" class="flex gap-2 items-center" id="create-token-form">
            <select name="lifetime" class="select select-bordered select-sm" aria-label="Key lifetime">
              <option value="">Never expires</option>
              <option value="30">Expires in 30 days</option>
              <option value="90">Expires in 90 days</option>
              <option value="365">Expires in 1 year</option>
            </select>
            <button class="btn btn-sm">Create key</button>
          </form>
        </div>
        <div :if={@new_token} class="alert alert-info text-sm">
          <span>
            Copy this key now — it won't be shown again:
            <code class="font-mono select-all">{@new_token}</code>
          </span>
        </div>
        <table :if={@api_tokens != []} class="table table-sm">
          <thead>
            <tr>
              <th>Key</th>
              <th>Expires</th>
              <th>Last used</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @api_tokens} id={"token-#{token.id}"}>
              <td class="font-mono">{token.prefix}</td>
              <td class="text-sm">
                <span :if={token.expires_at == nil} class="badge badge-ghost badge-sm">
                  never
                </span>
                <span
                  :if={token.expires_at != nil}
                  class={[
                    "badge badge-sm",
                    (Chat.token_expired?(token) && "badge-error") || "badge-ghost"
                  ]}
                >
                  {(Chat.token_expired?(token) && "expired") ||
                    Calendar.strftime(token.expires_at, "%b %d, %Y")}
                </span>
              </td>
              <td class="text-sm opacity-70">
                {if token.last_used_at,
                  do: Calendar.strftime(token.last_used_at, "%b %d %H:%M"),
                  else: "never"}
              </td>
              <td class="text-right">
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="revoke-token"
                  phx-value-token-id={token.id}
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p class="text-xs opacity-60">
          Use with
          <code>
            POST {(@app.mode == :completion && "/v1/completion-messages") || "/v1/chat-messages"}
          </code>
          and header <code>Authorization: Bearer app-…</code>
        </p>
      </div>
    </Layouts.console>
    """
  end
end
