defmodule FluxWeb.SiteLive.AppSite do
  @moduledoc """
  The public face of a published app at `/site/:token` — no login; the
  site token in the URL is the authorization. Chat apps get a conversation
  UI, completion apps a form built from the app's `input_form`. Visitors
  are tracked as anonymous end users (`web_…` refs on conversations).
  """
  use FluxWeb, :live_view

  alias Flux.Chat
  alias Flux.Chat.App

  @impl true
  def mount(%{"token" => token}, session, socket) do
    case Chat.get_app_by_site_token(token) do
      {:ok, %App{} = app} ->
        scope = Chat.site_scope(app)

        end_user_ref =
          session["site_visitor"] ||
            "web_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

        # Returning visitors resume their last conversation (chat modes).
        {conversation, messages} =
          if app.mode in [:chat, :advanced_chat] do
            case Chat.latest_conversation(scope, app.id, end_user_ref) do
              nil ->
                {nil, []}

              conversation ->
                messages =
                  scope
                  |> Chat.list_messages(conversation.id)
                  |> Enum.filter(&(&1.status in [:completed, :error] or &1.role == :user))

                {conversation, messages}
            end
          else
            {nil, []}
          end

        {:ok,
         assign(socket,
           page_title: app.name,
           app: app,
           visitor_ip: FluxWeb.SiteRateLimit.visitor_ip(socket),
           site_scope: scope,
           end_user_ref: end_user_ref,
           conversation: conversation,
           conversations: Chat.visitor_conversations(scope, app.id, end_user_ref),
           messages: messages,
           streaming_id: nil,
           streaming_text: ""
         )}

      {:error, :not_found} ->
        {:ok, assign(socket, page_title: "Not found", app: nil)}
    end
  end

  @impl true
  def handle_event("send", %{"content" => content}, socket) when content != "" do
    %{app: app, site_scope: scope} = socket.assigns

    if allowed?(socket) do
      conversation =
        socket.assigns.conversation ||
          Chat.create_conversation(scope, app, %{end_user_ref: socket.assigns.end_user_ref})

      case Chat.send_message(scope, app, conversation, content) do
        {:ok, user_message, assistant_message} ->
          conversations =
            if socket.assigns.conversation == nil do
              Chat.visitor_conversations(scope, app.id, socket.assigns.end_user_ref)
            else
              socket.assigns.conversations
            end

          {:noreply,
           assign(socket,
             conversation: conversation,
             conversations: conversations,
             messages: socket.assigns.messages ++ [user_message],
             streaming_id: assistant_message.id,
             streaming_text: ""
           )}

        {:error, :guardrail} ->
          {:noreply, put_flash(socket, :error, "That message isn't allowed here.")}

        {:error, :quota_exceeded} ->
          {:noreply, put_flash(socket, :error, "This app is over its daily usage limit.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Too many requests — please slow down.")}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("suggest", %{"question" => question}, socket) do
    handle_event("send", %{"content" => question}, socket)
  end

  def handle_event("start_over", _params, socket) do
    {:noreply, assign(socket, conversation: nil, messages: [], streaming_id: nil)}
  end

  def handle_event("switch_conversation", %{"conversation-id" => id}, socket) do
    %{site_scope: scope, end_user_ref: end_user_ref} = socket.assigns

    case Enum.find(socket.assigns.conversations, &(&1.id == id)) do
      %{end_user_ref: ^end_user_ref} = conversation ->
        messages =
          scope
          |> Chat.list_messages(conversation.id)
          |> Enum.filter(&(&1.status in [:completed, :error] or &1.role == :user))

        {:noreply,
         assign(socket, conversation: conversation, messages: messages, streaming_id: nil)}

      _not_yours ->
        {:noreply, socket}
    end
  end

  def handle_event("run_completion", params, socket) do
    %{app: app, site_scope: scope} = socket.assigns

    with true <- allowed?(socket),
         {:ok, conversation, _user_message, assistant_message} <-
           Chat.send_completion(scope, app, params["inputs"] || %{}, %{
             end_user_ref: socket.assigns.end_user_ref
           }) do
      {:noreply,
       assign(socket,
         conversation: conversation,
         messages: [],
         streaming_id: assistant_message.id,
         streaming_text: ""
       )}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Too many requests — please slow down.")}

      {:error, :guardrail} ->
        {:noreply, put_flash(socket, :error, "That message isn't allowed here.")}

      {:error, :quota_exceeded} ->
        {:noreply, put_flash(socket, :error, "This app is over its daily usage limit.")}

      {:error, :not_completion_app} ->
        {:noreply, socket}
    end
  end

  def handle_event("stop", _params, socket) do
    if id = socket.assigns.streaming_id do
      Chat.stop_generation(socket.assigns.site_scope, id)
    end

    {:noreply, socket}
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
     assign(socket,
       messages: socket.assigns.messages ++ [message],
       streaming_id: nil,
       streaming_text: ""
     )}
  end

  # Strict hex check so the theme value can be inlined into a <style> block.
  defp valid_accent(accent) do
    if is_binary(accent) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, accent), do: accent
  end

  defp allowed?(socket) do
    FluxWeb.SiteRateLimit.allow?(socket.assigns.app.site_token, socket.assigns.visitor_ip)
  end

  defp completion_output(messages) do
    case List.last(messages) do
      %{role: :assistant, status: :error, error: error} -> error
      %{role: :assistant, content: content} -> content
      _no_output_yet -> nil
    end
  end

  @impl true
  def render(%{app: nil} = assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center p-6">
      <div class="text-center space-y-2">
        <.icon name="hero-eye-slash" class="size-10 opacity-40 mx-auto" />
        <h1 class="font-semibold text-lg">This app is not available.</h1>
        <p class="text-sm opacity-60">The link may be wrong, or publishing was turned off.</p>
      </div>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <style :if={valid_accent(@app.site_theme["accent"])}>
      .btn-primary, .chat-bubble-primary {
        background-color: <%= valid_accent(@app.site_theme["accent"]) %> !important;
        border-color: <%= valid_accent(@app.site_theme["accent"]) %> !important;
        color: #fff !important;
      }
    </style>
    <main class="min-h-screen flex flex-col items-center p-4 sm:p-6">
      <div class="w-full max-w-2xl flex-1 flex flex-col gap-4">
        <header class="pt-2 flex items-center gap-3">
          <img
            :if={@app.site_theme["logo_url"]}
            src={@app.site_theme["logo_url"]}
            alt=""
            class="h-9 w-9 rounded object-contain"
          />
          <div>
            <h1 class="text-xl font-bold">{@app.site_theme["title"] || @app.name}</h1>
            <p :if={@app.description} class="text-sm opacity-70">{@app.description}</p>
          </div>
          <form
            :if={@app.mode in [:chat, :advanced_chat] and length(@conversations) > 1}
            phx-change="switch_conversation"
            class="ml-auto"
            id="conversation-switcher"
          >
            <select name="conversation-id" class="select select-bordered select-xs max-w-44">
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
        </header>

        <div :if={@app.mode in [:chat, :advanced_chat]} class="flex-1 flex flex-col gap-3">
          <div id="site-messages" class="flex-1 space-y-3 overflow-y-auto">
            <div
              :if={
                @messages == [] and @streaming_id == nil and @app.opening_statement not in [nil, ""]
              }
              class="chat chat-start"
            >
              <div class="chat-bubble whitespace-pre-wrap">{@app.opening_statement}</div>
            </div>
            <p
              :if={
                @messages == [] and @streaming_id == nil and
                  @app.opening_statement in [nil, ""]
              }
              class="text-sm opacity-60"
            >
              Say something to start the conversation.
            </p>
            <div
              :if={@messages == [] and @streaming_id == nil and @app.suggested_questions != []}
              class="flex flex-wrap gap-2"
            >
              <button
                :for={question <- @app.suggested_questions}
                type="button"
                class="btn btn-outline btn-xs"
                phx-click="suggest"
                phx-value-question={question}
              >
                {question}
              </button>
            </div>
            <div
              :for={message <- @messages}
              class={["chat", (message.role == :user && "chat-end") || "chat-start"]}
              id={"site-message-#{message.id}"}
            >
              <div class={[
                "chat-bubble",
                (message.role == :assistant and message.status != :error) ||
                  "whitespace-pre-wrap",
                message.role == :user && "chat-bubble-primary",
                message.status == :error && "chat-bubble-error"
              ]}>
                <%= cond do %>
                  <% message.status == :error -> %>
                    {message.error}
                  <% message.role == :assistant -> %>
                    <div class="markdown-chat">{FluxWeb.Markdown.render(message.content)}</div>
                  <% true -> %>
                    {message.content}
                <% end %>
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
                >
                  <.icon name="hero-document-arrow-down" class="size-3" /> {file["name"]}
                </a>
              </div>
              <div
                :if={message.role == :assistant and message.citations != []}
                class="chat-footer opacity-60 text-xs mt-0.5"
              >
                Sources: {message.citations
                |> Enum.map(& &1["document"])
                |> Enum.uniq()
                |> Enum.join(", ")}
              </div>
            </div>
            <div :if={@streaming_id} class="chat chat-start" id="site-streaming">
              <div class="chat-bubble whitespace-pre-wrap">
                {@streaming_text}<span class="animate-pulse">▌</span>
              </div>
            </div>
          </div>

          <form phx-submit="send" class="flex gap-2" id="site-chat-form">
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
            <button
              :if={@conversation != nil and @streaming_id == nil}
              type="button"
              class="btn btn-ghost"
              phx-click="start_over"
              title="Start a new conversation"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
          </form>
        </div>

        <div :if={@app.mode == :completion} class="space-y-4">
          <form phx-submit="run_completion" id="site-completion-form" class="space-y-3">
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
              <button
                :if={@streaming_id}
                type="button"
                class="btn btn-warning btn-sm"
                phx-click="stop"
              >
                Stop
              </button>
            </div>
          </form>

          <div
            :if={@streaming_id != nil or completion_output(@messages) != nil}
            id="site-completion-output"
            class="rounded-box bg-base-200 p-4 text-sm whitespace-pre-wrap"
          >
            {(@streaming_id && @streaming_text) || completion_output(@messages)}
            <span :if={@streaming_id} class="animate-pulse">▌</span>
          </div>
        </div>

        <footer class="py-2 text-center text-xs opacity-40">
          Powered by <span class="flux-wordmark not-italic">FluxCapacitor</span> ⚡
        </footer>
      </div>
    </main>
    <Layouts.flash_group flash={@flash} />
    """
  end
end
