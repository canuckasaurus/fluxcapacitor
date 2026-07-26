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
        {:ok,
         assign(socket,
           page_title: app.name,
           app: app,
           conversation: nil,
           messages: [],
           streaming_id: nil,
           streaming_text: "",
           api_tokens: Chat.list_api_tokens(scope, app.id),
           new_token: nil,
           can_manage: RBAC.can?(scope, :app_create_and_management)
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "App not found.")
         |> push_navigate(to: ~p"/console/apps")}
    end
  end

  @impl true
  def handle_event("send", %{"content" => content}, socket) when content != "" do
    scope = socket.assigns.current_scope
    app = socket.assigns.app

    conversation =
      socket.assigns.conversation || Chat.create_conversation(scope, app)

    {:ok, user_message, assistant_message} =
      Chat.send_message(scope, app, conversation, content)

    {:noreply,
     assign(socket,
       conversation: conversation,
       messages: socket.assigns.messages ++ [user_message],
       streaming_id: assistant_message.id,
       streaming_text: ""
     )}
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("stop", _params, socket) do
    if id = socket.assigns.streaming_id do
      Chat.stop_generation(socket.assigns.current_scope, id)
    end

    {:noreply, socket}
  end

  def handle_event("new-conversation", _params, socket) do
    {:noreply,
     assign(socket, conversation: nil, messages: [], streaming_id: nil, streaming_text: "")}
  end

  def handle_event("create-token", _params, socket) do
    case Chat.create_api_token(socket.assigns.current_scope, socket.assigns.app) do
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
    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [message],
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
        <div class="flex gap-2">
          <button class="btn btn-sm btn-ghost" phx-click="new-conversation">New conversation</button>
          <.link navigate={~p"/console/apps"} class="btn btn-sm btn-ghost">&larr; All apps</.link>
        </div>
      </div>

      <div class="card border border-base-200 p-6 space-y-4">
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
              "chat-bubble whitespace-pre-wrap",
              message.role == :user && "chat-bubble-primary",
              message.status == :error && "chat-bubble-error"
            ]}>
              {if message.status == :error, do: message.error, else: message.content}
            </div>
          </div>
          <div :if={@streaming_id} class="chat chat-start" id="streaming-bubble">
            <div class="chat-bubble whitespace-pre-wrap">
              {@streaming_text}<span class="animate-pulse">▌</span>
            </div>
          </div>
        </div>

        <form phx-submit="send" class="flex gap-2" id="chat-form">
          <input
            type="text"
            name="content"
            autocomplete="off"
            placeholder="Type a message…"
            class="input input-bordered flex-1"
            disabled={@streaming_id != nil}
          />
          <button :if={@streaming_id == nil} class="btn btn-primary">Send</button>
          <button :if={@streaming_id} type="button" class="btn btn-warning" phx-click="stop">
            Stop
          </button>
        </form>
      </div>

      <div :if={@can_manage} class="card border border-base-200 p-6 space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="font-semibold">API keys</h2>
          <button class="btn btn-sm" phx-click="create-token">Create key</button>
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
              <th>Last used</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @api_tokens} id={"token-#{token.id}"}>
              <td class="font-mono">{token.prefix}</td>
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
          Use with <code>POST /v1/chat-messages</code>
          and header <code>Authorization: Bearer app-…</code>
        </p>
      </div>
    </Layouts.console>
    """
  end
end
