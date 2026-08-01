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
         feedback_filter: :all,
         feedback: Chat.list_feedback(scope, app.id),
         quality: Chat.quality_stats(scope, app.id),
         annotations: Chat.list_annotations(scope, app.id),
         can_edit: RBAC.can?(scope, :app_edit),
         search_results: nil,
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
  def handle_event("filter_feedback", %{"filter" => filter}, socket)
      when filter in ~w(all like dislike) do
    filter = String.to_existing_atom(filter)
    scope = socket.assigns.current_scope

    {:noreply,
     assign(socket,
       feedback_filter: filter,
       feedback: Chat.list_feedback(scope, socket.assigns.app.id, filter)
     )}
  end

  def handle_event("save_annotation", %{"message-id" => message_id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.annotate_from_message(scope, socket.assigns.app, message_id) do
      {:ok, _annotation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved — matching questions now answer instantly.")
         |> assign(annotations: Chat.list_annotations(scope, socket.assigns.app.id))}

      {:error, :no_question} ->
        {:noreply, put_flash(socket, :error, "Could not find the question this reply answered.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the annotation.")}
    end
  end

  def handle_event("delete_annotation", %{"annotation-id" => id}, socket) do
    scope = socket.assigns.current_scope
    Chat.delete_annotation(scope, id)

    {:noreply, assign(socket, annotations: Chat.list_annotations(scope, socket.assigns.app.id))}
  end

  def handle_event("search", %{"query" => query}, socket) do
    results =
      case String.trim(query) do
        "" ->
          nil

        trimmed ->
          Chat.search_messages(socket.assigns.current_scope, socket.assigns.app.id, trimmed)
      end

    {:noreply, assign(socket, search_results: results)}
  end

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

      <div :if={@quality != []} class="card border border-base-200 p-6 space-y-3" id="quality-trends">
        <h2 class="font-semibold">Quality (last 14 days)</h2>
        <table class="table table-xs max-w-2xl">
          <thead>
            <tr>
              <th>Day</th>
              <th>Replies</th>
              <th>👍</th>
              <th>👎</th>
              <th>Annotation hits</th>
              <th class="w-40">Sentiment</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @quality}>
              <td>{row.day}</td>
              <td class="circuit-value">{row.replies}</td>
              <td class="circuit-value text-success">{row.likes}</td>
              <td class="circuit-value text-error">{row.dislikes}</td>
              <td class="circuit-value text-accent">{row.annotation_hits}</td>
              <td>
                <div class="flex h-2 rounded overflow-hidden bg-base-200">
                  <div
                    :if={row.likes > 0}
                    class="bg-success"
                    style={"width: #{round(row.likes / max(row.replies, 1) * 100)}%"}
                  >
                  </div>
                  <div
                    :if={row.dislikes > 0}
                    class="bg-error"
                    style={"width: #{round(row.dislikes / max(row.replies, 1) * 100)}%"}
                  >
                  </div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="feedback-review">
        <div class="flex items-center gap-3">
          <h2 class="font-semibold">Feedback</h2>
          <div class="join">
            <button
              :for={filter <- [:all, :like, :dislike]}
              class={[
                "btn btn-xs join-item",
                (@feedback_filter == filter && "btn-primary") || "btn-ghost"
              ]}
              phx-click="filter_feedback"
              phx-value-filter={filter}
            >
              {filter}
            </button>
          </div>
          <span class="text-xs opacity-60">{length(@feedback)} rated replies</span>
        </div>
        <p :if={@feedback == []} class="text-sm opacity-60">
          No rated replies{if @feedback_filter != :all, do: " with that rating"} yet.
        </p>
        <div
          :for={%{message: message, question: question} <- @feedback}
          class="rounded-box border border-base-200 p-3 space-y-1"
          id={"feedback-#{message.id}"}
        >
          <div class="flex items-center gap-2 text-xs opacity-60">
            <span class={[
              "badge badge-sm",
              (message.feedback == :like && "badge-success") || "badge-error"
            ]}>
              {(message.feedback == :like && "👍 liked") || "👎 disliked"}
            </span>
            <span>{Calendar.strftime(message.inserted_at, "%Y-%m-%d %H:%M")}</span>
            <button
              class="btn btn-ghost btn-xs ml-auto"
              phx-click="select"
              phx-value-conversation-id={message.conversation_id}
            >
              View conversation
            </button>
          </div>
          <p :if={question} class="text-sm opacity-70 truncate">
            <span class="font-semibold">Q:</span> {question}
          </p>
          <p class="text-sm whitespace-pre-wrap break-words max-h-24 overflow-y-auto">
            {message.content}
          </p>
          <button
            :if={@can_edit and message.feedback == :like and question}
            class="btn btn-outline btn-xs"
            phx-click="save_annotation"
            phx-value-message-id={message.id}
          >
            <.icon name="hero-bookmark" class="size-3" /> Save as annotation
          </button>
        </div>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="annotations">
        <div class="flex items-center gap-3">
          <h2 class="font-semibold">Annotations</h2>
          <span class="text-xs opacity-60">
            Matching questions answer instantly without calling the model.
          </span>
        </div>
        <p :if={@annotations == []} class="text-sm opacity-60">
          No annotations yet — save a liked reply from the feedback list above.
        </p>
        <div
          :for={annotation <- @annotations}
          class="rounded-box border border-base-200 p-3 space-y-1"
          id={"annotation-#{annotation.id}"}
        >
          <div class="flex items-center gap-2 text-xs opacity-60">
            <span class="badge badge-ghost badge-sm">{annotation.hit_count} hits</span>
            <span>{Calendar.strftime(annotation.inserted_at, "%Y-%m-%d %H:%M")}</span>
            <button
              :if={@can_edit}
              class="btn btn-ghost btn-xs text-error ml-auto"
              phx-click="delete_annotation"
              phx-value-annotation-id={annotation.id}
              data-confirm="Delete this annotation?"
            >
              Delete
            </button>
          </div>
          <p class="text-sm font-semibold">{annotation.question}</p>
          <p class="text-sm whitespace-pre-wrap break-words max-h-24 overflow-y-auto">
            {annotation.answer}
          </p>
        </div>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="conversation-search">
        <form phx-submit="search" class="flex gap-2" id="search-form">
          <input
            type="text"
            name="query"
            placeholder="Search messages…"
            class="input input-bordered input-sm flex-1 max-w-md"
          />
          <button class="btn btn-primary btn-sm">Search</button>
        </form>
        <p :if={@search_results == []} class="text-sm opacity-60">No messages matched.</p>
        <div
          :for={%{message: message, conversation: conversation} <- @search_results || []}
          class="rounded-box border border-base-200 p-3 space-y-1"
        >
          <div class="flex items-center gap-2 text-xs opacity-60">
            <span class={[
              "badge badge-sm",
              (message.role == :user && "badge-primary") || "badge-ghost"
            ]}>
              {message.role}
            </span>
            <span>{conversation.title || "Untitled conversation"}</span>
            <span>{Calendar.strftime(message.inserted_at, "%Y-%m-%d %H:%M")}</span>
            <button
              class="btn btn-ghost btn-xs ml-auto"
              phx-click="select"
              phx-value-conversation-id={conversation.id}
            >
              View conversation
            </button>
          </div>
          <p class="text-sm whitespace-pre-wrap break-words max-h-16 overflow-y-auto">
            {message.content}
          </p>
        </div>
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
