defmodule FluxWeb.ConsoleLive.AppMonitor do
  @moduledoc "Browse an app's conversations, messages, and feedback (app_monitor)."
  use FluxWeb, :live_view

  alias Flux.Chat
  alias Flux.Chat.App
  alias Flux.RBAC

  @impl true
  def mount(%{"id" => app_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with true <- RBAC.can?(scope, :app_monitor) || :unauthorized,
         %App{} = app <- Chat.get_app(scope, app_id) do
      {:ok,
       assign(socket,
         page_title: "#{app.name} — monitoring",
         app: app,
         conversations: Chat.list_conversations(scope, app.id, 50),
         usage: Chat.usage_stats(scope, app.id),
         selected_id: nil,
         messages: []
       )}
    else
      :unauthorized ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have permission to monitor apps.")
         |> push_navigate(to: ~p"/console/apps")}

      {:error, :not_found} ->
        {:ok,
         socket |> put_flash(:error, "App not found.") |> push_navigate(to: ~p"/console/apps")}
    end
  end

  @impl true
  def handle_event("select", %{"conversation-id" => id}, socket) do
    scope = socket.assigns.current_scope

    if socket.assigns.selected_id == id do
      {:noreply, assign(socket, selected_id: nil, messages: [])}
    else
      {:noreply, assign(socket, selected_id: id, messages: Chat.list_messages(scope, id))}
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
          <h1 class="text-2xl font-bold">{@app.name} — monitoring</h1>
          <p class="opacity-60 text-sm">Recent conversations and their messages.</p>
        </div>
        <.link navigate={~p"/console/apps/#{@app.id}"} class="btn btn-sm btn-ghost">
          &larr; Back to app
        </.link>
      </div>

      <div :if={@usage != []} class="card border border-base-200 p-6 space-y-3">
        <div class="flex items-center gap-6">
          <h2 class="font-semibold">Usage (last 14 days)</h2>
          <div class="stats stats-horizontal">
            <div class="stat py-1 px-4">
              <div class="stat-title text-xs">Replies</div>
              <div class="stat-value text-lg">
                {@usage |> Enum.map(& &1.messages) |> Enum.sum()}
              </div>
            </div>
            <div class="stat py-1 px-4">
              <div class="stat-title text-xs">Tokens in</div>
              <div class="stat-value text-lg">
                {@usage |> Enum.map(&(&1.input_tokens || 0)) |> Enum.sum()}
              </div>
            </div>
            <div class="stat py-1 px-4">
              <div class="stat-title text-xs">Tokens out</div>
              <div class="stat-value text-lg">
                {@usage |> Enum.map(&(&1.output_tokens || 0)) |> Enum.sum()}
              </div>
            </div>
          </div>
        </div>
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Day</th>
              <th>Replies</th>
              <th>Tokens in</th>
              <th>Tokens out</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @usage}>
              <td>{row.day}</td>
              <td>{row.messages}</td>
              <td>{row.input_tokens || 0}</td>
              <td>{row.output_tokens || 0}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@conversations == []} class="text-sm opacity-60">No conversations yet.</p>

      <div :for={conversation <- @conversations} class="card border border-base-200">
        <button
          type="button"
          class="flex items-center gap-3 px-4 py-3 text-left hover:bg-base-200/60"
          phx-click="select"
          phx-value-conversation-id={conversation.id}
        >
          <span class="font-semibold text-sm">
            {conversation.title || "Untitled conversation"}
          </span>
          <span :if={conversation.end_user_ref} class="badge badge-ghost badge-sm font-mono">
            {conversation.end_user_ref}
          </span>
          <span class="ml-auto text-xs opacity-60">
            {Calendar.strftime(conversation.inserted_at, "%Y-%m-%d %H:%M")}
          </span>
        </button>

        <div :if={@selected_id == conversation.id} class="border-t border-base-200 p-4 space-y-2">
          <div :for={message <- @messages} class="flex items-start gap-2 text-sm">
            <span class={[
              "badge badge-sm shrink-0",
              (message.role == :user && "badge-primary") || "badge-ghost"
            ]}>
              {message.role}
            </span>
            <div class="min-w-0 flex-1">
              <p class="whitespace-pre-wrap break-words">
                {if message.status == :error, do: message.error, else: message.content}
              </p>
              <p class="text-xs opacity-50">
                {message.status}
                <span :if={message.feedback}>· feedback: {message.feedback}</span>
                <span :if={message.usage != %{}}>
                  · {message.usage["input_tokens"]}in/{message.usage["output_tokens"]}out
                </span>
              </p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
