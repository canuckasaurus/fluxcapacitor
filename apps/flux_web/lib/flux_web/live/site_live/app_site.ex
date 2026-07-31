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
  def mount(%{"token" => token}, _session, socket) do
    case Chat.get_app_by_site_token(token) do
      {:ok, %App{} = app} ->
        {:ok,
         assign(socket,
           page_title: app.name,
           app: app,
           visitor_ip: FluxWeb.SiteRateLimit.visitor_ip(socket),
           site_scope: Chat.site_scope(app),
           end_user_ref:
             "web_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
           conversation: nil,
           messages: [],
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

      {:ok, user_message, assistant_message} =
        Chat.send_message(scope, app, conversation, content)

      {:noreply,
       assign(socket,
         conversation: conversation,
         messages: socket.assigns.messages ++ [user_message],
         streaming_id: assistant_message.id,
         streaming_text: ""
       )}
    else
      {:noreply, put_flash(socket, :error, "Too many requests — please slow down.")}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

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
    <main class="min-h-screen flex flex-col items-center p-4 sm:p-6">
      <div class="w-full max-w-2xl flex-1 flex flex-col gap-4">
        <header class="pt-2">
          <h1 class="text-xl font-bold">{@app.name}</h1>
          <p :if={@app.description} class="text-sm opacity-70">{@app.description}</p>
        </header>

        <div :if={@app.mode == :chat} class="flex-1 flex flex-col gap-3">
          <div id="site-messages" class="flex-1 space-y-3 overflow-y-auto">
            <p :if={@messages == [] and @streaming_id == nil} class="text-sm opacity-60">
              Say something to start the conversation.
            </p>
            <div
              :for={message <- @messages}
              class={["chat", (message.role == :user && "chat-end") || "chat-start"]}
              id={"site-message-#{message.id}"}
            >
              <div class={[
                "chat-bubble whitespace-pre-wrap",
                message.role == :user && "chat-bubble-primary",
                message.status == :error && "chat-bubble-error"
              ]}>
                {if message.status == :error, do: message.error, else: message.content}
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
          Powered by FluxCapacitor
        </footer>
      </div>
    </main>
    <Layouts.flash_group flash={@flash} />
    """
  end
end
