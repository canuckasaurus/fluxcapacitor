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
         handoffs: Chat.handoff_queue(scope, app.id),
         ab_stats: (app.ab_split > 0 && Chat.app_ab_stats(scope, app.id)) || nil,
         prompt_ab_stats: (app.prompt_split > 0 && Chat.prompt_ab_stats(scope, app.id)) || nil,
         handoff_sla: Chat.handoff_sla(scope, app.id),
         conversation_usage: nil,
         conversation_evals: Flux.ConversationEvals.list_conversation_evals(scope, app.id),
         trashed_conversations: Chat.list_trashed_conversations(scope, app.id),
         visitor_stats: Chat.visitor_stats(scope, app.id),
         selected_conversation_ids: MapSet.new(),
         all_labels: Chat.conversation_labels(scope, app.id),
         label_filter: nil,
         usage: Chat.usage_stats(scope, app.id),
         feedback_filter: :all,
         feedback: Chat.list_feedback(scope, app.id),
         quality: Chat.quality_stats(scope, app.id),
         topics: Chat.topic_clusters(scope, app.id),
         annotations: Chat.list_annotations(scope, app.id),
         can_edit: RBAC.can?(scope, :app_edit),
         labeling_projects: Flux.Labeling.list_projects(scope),
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

  # Palette deep links land here: ?conversation=<id> opens it selected.
  @impl true
  def handle_params(%{"conversation" => conversation_id}, _uri, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     assign(socket,
       selected_id: conversation_id,
       messages: Chat.list_messages(scope, conversation_id),
       conversation_usage: Chat.conversation_usage(scope, conversation_id)
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "human_reply",
        %{"conversation-id" => conversation_id, "content" => content},
        socket
      ) do
    scope = socket.assigns.current_scope

    case String.trim(to_string(content)) do
      "" ->
        {:noreply, socket}

      content ->
        case Chat.human_reply(scope, conversation_id, content) do
          {:ok, _message} ->
            {:noreply,
             socket
             |> put_flash(:info, "Reply sent — the visitor sees it live.")
             |> assign(handoffs: Chat.handoff_queue(scope, socket.assigns.app.id))}

          _error ->
            {:noreply, put_flash(socket, :error, "Could not send the reply.")}
        end
    end
  end

  def handle_event(
        "set_labels",
        %{"conversation-id" => conversation_id, "labels" => labels},
        socket
      ) do
    scope = socket.assigns.current_scope

    case Chat.set_conversation_labels(scope, conversation_id, String.split(labels, ",")) do
      {:ok, _conversation} ->
        {:noreply,
         assign(socket,
           conversations: Chat.list_conversations(scope, socket.assigns.app.id, 50),
           all_labels: Chat.conversation_labels(scope, socket.assigns.app.id)
         )}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the labels.")}
    end
  end

  def handle_event("filter_label", %{"label" => label}, socket) do
    {:noreply, assign(socket, label_filter: (label == "" && nil) || label)}
  end

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

  def handle_event("send_to_labeling", %{"message-id" => message_id} = params, socket) do
    entry = Enum.find(socket.assigns.feedback, &(&1.message.id == message_id))
    project_id = params["project-id"]

    with %{message: message, question: question} when is_binary(question) <- entry,
         {:ok, _task} <-
           Flux.Labeling.queue_item(socket.assigns.current_scope, project_id, %{
             "question" => question,
             "answer" => message.content,
             "feedback" => to_string(message.feedback)
           }) do
      {:noreply, put_flash(socket, :info, "Queued for labeling.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That labeling project no longer exists.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not queue the reply for labeling.")}
    end
  end

  def handle_event("toggle_conversation_select", %{"conversation-id" => id}, socket) do
    selected = socket.assigns.selected_conversation_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected_conversation_ids: selected)}
  end

  def handle_event("clear_conversation_selection", _params, socket) do
    {:noreply, assign(socket, selected_conversation_ids: MapSet.new())}
  end

  def handle_event("bulk_label_conversations", %{"labels" => labels}, socket) do
    scope = socket.assigns.current_scope
    ids = MapSet.to_list(socket.assigns.selected_conversation_ids)

    for id <- ids do
      Chat.set_conversation_labels(scope, id, String.split(labels, ","))
    end

    {:noreply,
     socket
     |> put_flash(:info, "Labeled #{length(ids)} conversations.")
     |> assign(
       conversations: Chat.list_conversations(scope, socket.assigns.app.id, 50),
       all_labels: Chat.conversation_labels(scope, socket.assigns.app.id),
       selected_conversation_ids: MapSet.new()
     )}
  end

  def handle_event("bulk_delete_conversations", _params, socket) do
    scope = socket.assigns.current_scope
    ids = MapSet.to_list(socket.assigns.selected_conversation_ids)

    for id <- ids, do: Chat.delete_conversation(scope, id)

    {:noreply,
     socket
     |> put_flash(:info, "Moved #{length(ids)} conversations to the trash.")
     |> assign(
       conversations: Chat.list_conversations(scope, socket.assigns.app.id, 50),
       trashed_conversations: Chat.list_trashed_conversations(scope, socket.assigns.app.id),
       selected_conversation_ids: MapSet.new()
     )}
  end

  def handle_event("forget_visitor", %{"ref" => ref}, socket) do
    scope = socket.assigns.current_scope

    case Chat.forget_visitor(scope, socket.assigns.app, ref) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Forgot #{ref}: #{count} conversations and their files removed.")
         |> assign(
           conversations: Chat.list_conversations(scope, socket.assigns.app.id, 50),
           visitor_stats: Chat.visitor_stats(scope, socket.assigns.app.id)
         )}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not forget that visitor.")}
    end
  end

  def handle_event("purge_conversation", %{"conversation-id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.purge_conversation(scope, id) do
      {:ok, _conversation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation permanently deleted.")
         |> assign(
           trashed_conversations: Chat.list_trashed_conversations(scope, socket.assigns.app.id)
         )}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not purge that conversation.")}
    end
  end

  def handle_event("restore_conversation", %{"conversation-id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.restore_conversation(scope, id) do
      {:ok, _conversation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation restored.")
         |> assign(
           conversations: Chat.list_conversations(scope, socket.assigns.app.id, 50),
           trashed_conversations: Chat.list_trashed_conversations(scope, socket.assigns.app.id)
         )}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not restore the conversation.")}
    end
  end

  def handle_event("import_annotations", %{"csv" => csv}, socket) do
    scope = socket.assigns.current_scope

    rows =
      case Flux.CSV.parse(csv) do
        [["question", "answer" | _rest] | data] -> data
        data -> data
      end

    case Chat.import_annotations(scope, socket.assigns.app, rows) do
      {:ok, imported} ->
        {:noreply,
         socket
         |> put_flash(:info, "Imported #{imported} annotations.")
         |> assign(annotations: Chat.list_annotations(scope, socket.assigns.app.id))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not import the annotations.")}
    end
  end

  def handle_event("delete_annotation", %{"annotation-id" => id}, socket) do
    scope = socket.assigns.current_scope
    Chat.delete_annotation(scope, id)

    {:noreply, assign(socket, annotations: Chat.list_annotations(scope, socket.assigns.app.id))}
  end

  def handle_event("claim_handoff", %{"conversation-id" => conversation_id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.assign_handoff(scope, conversation_id, scope.account.id) do
      {:ok, _conversation} ->
        {:noreply, assign(socket, handoffs: Chat.handoff_queue(scope, socket.assigns.app.id))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not claim the conversation.")}
    end
  end

  def handle_event("release_handoff", %{"conversation-id" => conversation_id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.assign_handoff(scope, conversation_id, nil) do
      {:ok, _conversation} ->
        {:noreply, assign(socket, handoffs: Chat.handoff_queue(scope, socket.assigns.app.id))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not release the conversation.")}
    end
  end

  def handle_event("toggle_annotation", %{"annotation-id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Enum.find(socket.assigns.annotations, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      annotation ->
        Chat.update_annotation(scope, id, %{enabled: not annotation.enabled})

        {:noreply,
         assign(socket, annotations: Chat.list_annotations(scope, socket.assigns.app.id))}
    end
  end

  def handle_event(
        "update_annotation",
        %{"annotation_id" => id, "question" => question, "answer" => answer},
        socket
      ) do
    scope = socket.assigns.current_scope

    case Chat.update_annotation(scope, id, %{question: question, answer: answer}) do
      {:ok, _annotation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Annotation updated.")
         |> assign(annotations: Chat.list_annotations(scope, socket.assigns.app.id))}

      {:error, :empty} ->
        {:noreply, put_flash(socket, :error, "Question and answer can't be blank.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the annotation.")}
    end
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
      {:noreply, assign(socket, selected_id: nil, messages: [], conversation_usage: nil)}
    else
      {:noreply,
       assign(socket,
         selected_id: id,
         messages: Chat.list_messages(scope, id),
         conversation_usage: Chat.conversation_usage(scope, id)
       )}
    end
  end

  def handle_event("add_conversation_eval", params, socket) do
    scope = socket.assigns.current_scope

    attrs = %{
      "name" => params["name"],
      "expectation" => params["expectation"],
      "schedule" => params["schedule"],
      "turns" => String.split(params["turns"] || "", ["\r\n", "\n"])
    }

    case Flux.ConversationEvals.create_conversation_eval(scope, socket.assigns.app, attrs) do
      {:ok, _eval} ->
        {:noreply, refresh_conversation_evals(socket)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "Needs a name, an expectation, and at least one turn.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit apps.")}
    end
  end

  def handle_event("run_conversation_eval", %{"eval-id" => id}, socket) do
    case Flux.ConversationEvals.run_conversation_eval(socket.assigns.current_scope, id) do
      {:ok, _eval} -> {:noreply, refresh_conversation_evals(socket)}
      _error -> {:noreply, put_flash(socket, :error, "The conversation eval could not run.")}
    end
  end

  def handle_event("delete_conversation_eval", %{"eval-id" => id}, socket) do
    Flux.ConversationEvals.delete_conversation_eval(socket.assigns.current_scope, id)
    {:noreply, refresh_conversation_evals(socket)}
  end

  defp refresh_conversation_evals(socket) do
    assign(socket,
      conversation_evals:
        Flux.ConversationEvals.list_conversation_evals(
          socket.assigns.current_scope,
          socket.assigns.app.id
        )
    )
  end

  # Direct-model apps price against their bound model; chatflow apps get
  # their cost on the flux runs instead (nil here hides the stat).
  defp estimated_cost(app, usage) do
    input = usage |> Enum.map(&(&1.input_tokens || 0)) |> Enum.sum()
    output = usage |> Enum.map(&(&1.output_tokens || 0)) |> Enum.sum()

    with model when is_binary(model) <- app.model,
         true <- input + output > 0,
         {:ok, cost} <- Flux.Pricing.estimate(app.workspace_id, model, input, output) do
      cost
    else
      _unknown_or_zero -> nil
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
        <div class="flex gap-2">
          <.link
            href={~p"/console/apps/#{@app.id}/monitor-export?kind=usage"}
            class="btn btn-sm btn-ghost"
            title="Daily usage stats (90 days) as CSV"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Usage CSV
          </.link>
          <.link
            href={~p"/console/apps/#{@app.id}/monitor-export?kind=feedback"}
            class="btn btn-sm btn-ghost"
            title="Rated replies with their questions as CSV"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Feedback CSV
          </.link>
          <.link
            href={~p"/console/apps/#{@app.id}/monitor-export?kind=conversations"}
            class="btn btn-sm btn-ghost"
            title="Every conversation's messages as CSV (up to 10k rows)"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Conversations CSV
          </.link>
          <.link navigate={~p"/console/apps/#{@app.id}"} class="btn btn-sm btn-ghost">
            &larr; Back to app
          </.link>
        </div>
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
            <div :if={estimated_cost(@app, @usage)} class="stat py-1 px-4" id="app-cost">
              <div class="stat-title text-xs">Est. cost</div>
              <div class="stat-value text-lg">
                ~${:erlang.float_to_binary(estimated_cost(@app, @usage), decimals: 4)}
              </div>
              <div class="stat-desc">{@app.model}</div>
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

      <div :if={@topics != []} class="card border border-base-200 p-6 space-y-3" id="topics-card">
        <h2 class="font-semibold">Topics</h2>
        <p class="text-xs opacity-60">
          Recent questions clustered by word overlap — what people actually ask.
        </p>
        <div class="space-y-2">
          <div :for={topic <- @topics} class="flex items-center gap-3">
            <span class="badge badge-primary badge-sm w-10 justify-center">{topic.count}</span>
            <span class="text-sm font-semibold">{topic.name}</span>
            <span class="text-xs opacity-60 truncate max-w-md">e.g. “{topic.example}”</span>
          </div>
        </div>
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
          <a
            href={~p"/console/apps/#{@app.id}/finetune-export"}
            class="btn btn-ghost btn-xs ml-auto"
            id="finetune-export-link"
          >
            Fine-tune JSONL (liked)
          </a>
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
          <p
            :if={message.feedback_comment}
            class="text-sm border-l-2 border-warning pl-2 whitespace-pre-wrap break-words"
          >
            <span class="font-semibold opacity-70">Visitor said:</span> {message.feedback_comment}
          </p>
          <button
            :if={@can_edit and message.feedback == :like and question}
            class="btn btn-outline btn-xs"
            phx-click="save_annotation"
            phx-value-message-id={message.id}
          >
            <.icon name="hero-bookmark" class="size-3" /> Save as annotation
          </button>
          <button
            :for={project <- @labeling_projects}
            :if={@can_edit and question}
            class="btn btn-outline btn-xs"
            phx-click="send_to_labeling"
            phx-value-message-id={message.id}
            phx-value-project-id={project.id}
          >
            <.icon name="hero-tag" class="size-3" /> Label in {project.name}
          </button>
        </div>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="annotations">
        <div class="flex items-center gap-3">
          <h2 class="font-semibold">Annotations</h2>
          <span class="text-xs opacity-60">
            Matching questions answer instantly without calling the model.
          </span>
          <a
            :if={@annotations != []}
            href={~p"/console/apps/#{@app.id}/monitor-export?kind=annotations"}
            class="btn btn-ghost btn-xs ml-auto"
          >
            <.icon name="hero-arrow-down-tray" class="size-3" /> CSV
          </a>
        </div>
        <p :if={@annotations == []} class="text-sm opacity-60">
          No annotations yet — save a liked reply from the feedback list above.
        </p>
        <form
          :if={@can_edit}
          phx-submit="import_annotations"
          class="space-y-2"
          id="import-annotations-form"
        >
          <textarea
            name="csv"
            rows="2"
            placeholder={"Paste CSV to import — question,answer per line\n\"How do I reset?\",\"Settings → Reset.\""}
            class="textarea textarea-bordered textarea-sm w-full font-mono"
          ></textarea>
          <button class="btn btn-outline btn-xs">Import CSV</button>
        </form>
        <div
          :for={annotation <- @annotations}
          class="rounded-box border border-base-200 p-3 space-y-1"
          id={"annotation-#{annotation.id}"}
        >
          <div class="flex items-center gap-2 text-xs opacity-60">
            <span class="badge badge-ghost badge-sm">{annotation.hit_count} hits</span>
            <span :if={not annotation.enabled} class="badge badge-warning badge-sm">
              disabled
            </span>
            <span>{Calendar.strftime(annotation.inserted_at, "%Y-%m-%d %H:%M")}</span>
            <span :if={@can_edit} class="ml-auto flex items-center gap-1">
              <button
                class="btn btn-ghost btn-xs"
                phx-click="toggle_annotation"
                phx-value-annotation-id={annotation.id}
              >
                {(annotation.enabled && "Disable") || "Enable"}
              </button>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="delete_annotation"
                phx-value-annotation-id={annotation.id}
                data-confirm="Delete this annotation?"
              >
                Delete
              </button>
            </span>
          </div>
          <p class="text-sm font-semibold">{annotation.question}</p>
          <p class="text-sm whitespace-pre-wrap break-words max-h-24 overflow-y-auto">
            {annotation.answer}
          </p>
          <details :if={@can_edit}>
            <summary class="text-xs opacity-60 cursor-pointer">Edit</summary>
            <form
              phx-submit="update_annotation"
              id={"edit-annotation-#{annotation.id}"}
              class="space-y-2 pt-2"
            >
              <input type="hidden" name="annotation_id" value={annotation.id} />
              <input
                type="text"
                name="question"
                value={annotation.question}
                class="input input-bordered input-sm w-full"
                required
              />
              <textarea
                name="answer"
                rows="2"
                class="textarea textarea-bordered textarea-sm w-full"
                required
              >{annotation.answer}</textarea>
              <button class="btn btn-primary btn-xs">Save (re-embeds a changed question)</button>
            </form>
          </details>
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

      <div
        :if={@prompt_ab_stats}
        class="card border border-base-200 p-4 space-y-2"
        id="prompt-ab-card"
      >
        <h2 class="font-semibold text-sm">
          Prompt A/B — {@app.prompt_split}% of conversations use Prompt B
        </h2>
        <table class="table table-xs max-w-xl">
          <thead>
            <tr>
              <th>Arm</th>
              <th>Replies</th>
              <th>👍</th>
              <th>👎</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={arm <- ~w(a b)}>
              <td class="font-semibold uppercase">{arm}</td>
              <td>{@prompt_ab_stats[arm].replies}</td>
              <td>{@prompt_ab_stats[arm].likes}</td>
              <td>{@prompt_ab_stats[arm].dislikes}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@ab_stats} class="card border border-base-200 p-4 space-y-2" id="model-ab-card">
        <h2 class="font-semibold text-sm">
          Model A/B — {@app.provider_plugin_id}/{@app.model} vs {@app.ab_provider_plugin_id}/{@app.ab_model} ({@app.ab_split}% B)
        </h2>
        <table class="table table-xs max-w-xl">
          <thead>
            <tr>
              <th>Variant</th>
              <th>Replies</th>
              <th>👍</th>
              <th>👎</th>
              <th>Tokens</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{variant, label} <- [{"a", "A (primary)"}, {"b", "B (challenger)"}]}>
              <td>{label}</td>
              <td>{@ab_stats[variant].replies}</td>
              <td>{@ab_stats[variant].likes}</td>
              <td>{@ab_stats[variant].dislikes}</td>
              <td class="font-mono">{@ab_stats[variant].tokens}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card border border-base-200 p-4 space-y-3" id="conversation-evals">
        <h2 class="font-semibold text-sm">
          <.icon name="hero-chat-bubble-left-right" class="size-4 inline" /> Conversation evals
        </h2>
        <p class="text-xs opacity-60">
          Scripted dialogues replayed through the app and judged as a whole —
          catches behaviors that only show up across turns.
        </p>
        <div
          :for={eval <- @conversation_evals}
          class="rounded-box border border-base-200 p-3 space-y-1"
          id={"conversation-eval-#{eval.id}"}
        >
          <div class="flex items-center gap-2">
            <span class="font-semibold text-sm">{eval.name}</span>
            <span class="badge badge-ghost badge-sm">{length(eval.turns)} turns</span>
            <span :if={eval.schedule} class="badge badge-ghost badge-sm font-mono">
              {eval.schedule}
            </span>
            <span
              :if={eval.last_score}
              class={[
                "badge badge-sm",
                (eval.last_score >= 0.7 && "badge-success") || "badge-error"
              ]}
            >
              {eval.last_score}
            </span>
            <span :if={eval.last_run_at} class="text-xs opacity-50">
              {Calendar.strftime(eval.last_run_at, "%Y-%m-%d %H:%M")}
            </span>
            <div :if={@can_edit} class="ml-auto flex gap-1">
              <button
                class="btn btn-primary btn-xs"
                phx-click="run_conversation_eval"
                phx-value-eval-id={eval.id}
              >
                Run
              </button>
              <button
                class="btn btn-ghost btn-xs"
                phx-click="delete_conversation_eval"
                phx-value-eval-id={eval.id}
              >
                <.icon name="hero-trash" class="size-3" />
              </button>
            </div>
          </div>
          <p :if={eval.last_reason} class="text-xs opacity-70">{eval.last_reason}</p>
          <details :if={eval.last_transcript != []}>
            <summary class="text-xs opacity-60 cursor-pointer">Last transcript</summary>
            <div class="space-y-1 mt-1 max-h-48 overflow-y-auto">
              <p :for={message <- eval.last_transcript} class="text-xs">
                <span class="font-semibold">{message["role"]}:</span> {message["content"]}
              </p>
            </div>
          </details>
        </div>
        <form
          :if={@can_edit}
          phx-submit="add_conversation_eval"
          class="space-y-2"
          id="add-conversation-eval"
        >
          <div class="flex gap-2">
            <input
              type="text"
              name="name"
              placeholder="Name"
              class="input input-bordered input-sm w-48"
              required
            />
            <input
              type="text"
              name="expectation"
              placeholder="Expectation — what a good dialogue looks like"
              class="input input-bordered input-sm flex-1"
              required
            />
            <input
              type="text"
              name="schedule"
              placeholder="cron (optional)"
              class="input input-bordered input-sm w-36 font-mono"
              title="Re-run unattended on this schedule; score drops raise a notification"
            />
          </div>
          <textarea
            name="turns"
            rows="3"
            placeholder="User turns, one per line"
            class="textarea textarea-bordered textarea-sm w-full font-mono"
            required
          ></textarea>
          <button class="btn btn-outline btn-sm">Add conversation eval</button>
        </form>
      </div>

      <div
        :if={@handoffs != []}
        class="card border border-warning/60 p-4 space-y-3"
        id="handoff-queue"
      >
        <h2 class="font-semibold text-sm">
          <.icon name="hero-hand-raised" class="size-4 inline text-warning" />
          Waiting for a human ({length(@handoffs)})
          <span :if={@handoff_sla} class="badge badge-ghost badge-sm" id="handoff-sla">
            median first reply {format_sla(@handoff_sla.median_seconds)} ({@handoff_sla.count} handoffs, 30d)
          </span>
        </h2>
        <div :for={conversation <- @handoffs} class="space-y-1" id={"handoff-#{conversation.id}"}>
          <p class="text-sm">
            <span class="font-semibold">{conversation.title || "Untitled conversation"}</span>
            <span :if={conversation.visitor_name || conversation.visitor_email} class="text-xs">
              ({[conversation.visitor_name, conversation.visitor_email]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" · ")})
            </span>
            <span class="text-xs opacity-60">
              — waiting since {Calendar.strftime(conversation.handoff_requested_at, "%H:%M")}
            </span>
            <span :if={conversation.assigned_account} class="badge badge-info badge-sm">
              {conversation.assigned_account.email}
            </span>
            <button
              :if={conversation.assigned_account == nil}
              class="btn btn-outline btn-xs"
              phx-click="claim_handoff"
              phx-value-conversation-id={conversation.id}
            >
              Claim
            </button>
            <button
              :if={
                conversation.assigned_account != nil and
                  conversation.assigned_account_id == @current_scope.account.id
              }
              class="btn btn-ghost btn-xs"
              phx-click="release_handoff"
              phx-value-conversation-id={conversation.id}
            >
              Release
            </button>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="select"
              phx-value-conversation-id={conversation.id}
            >
              View
            </button>
          </p>
          <form
            phx-submit="human_reply"
            class="flex gap-2"
            id={"handoff-reply-#{conversation.id}"}
          >
            <input type="hidden" name="conversation-id" value={conversation.id} />
            <input
              type="text"
              name="content"
              placeholder="Reply as a human — the visitor sees it live"
              class="input input-bordered input-sm flex-1"
              autocomplete="off"
            />
            <button class="btn btn-primary btn-sm">Send</button>
          </form>
        </div>
      </div>

      <div
        :if={@visitor_stats != []}
        class="card border border-base-200 p-4 space-y-2"
        id="visitor-stats"
      >
        <h2 class="font-semibold text-sm">
          <.icon name="hero-users" class="size-4 inline" /> Visitors
        </h2>
        <table class="table table-xs max-w-3xl">
          <thead>
            <tr>
              <th>Visitor</th>
              <th>Conversations</th>
              <th>Messages</th>
              <th>Tokens</th>
              <th>👍</th>
              <th>👎</th>
              <th>Last seen</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={visitor <- @visitor_stats}>
              <td class="font-mono">{visitor.ref}</td>
              <td>{visitor.conversations}</td>
              <td>{visitor.messages}</td>
              <td class="font-mono">{visitor.tokens}</td>
              <td>{visitor.likes}</td>
              <td>{visitor.dislikes}</td>
              <td class="text-xs opacity-60">
                {visitor.last_seen && Calendar.strftime(visitor.last_seen, "%Y-%m-%d %H:%M")}
              </td>
              <td>
                <button
                  :if={@can_edit}
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="forget_visitor"
                  phx-value-ref={visitor.ref}
                  data-confirm={"Permanently delete every conversation, message, and upload for #{visitor.ref}? This is the GDPR forget — no trash, no undo."}
                >
                  Forget
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@trashed_conversations != []}
        class="card border border-base-200 p-4 space-y-2"
        id="conversation-trash"
      >
        <h2 class="font-semibold text-sm">
          <.icon name="hero-trash" class="size-4 inline" />
          Trash ({length(@trashed_conversations)}) — purged after 30 days
        </h2>
        <p :for={conversation <- @trashed_conversations} class="text-sm flex items-center gap-2">
          <span>{conversation.title || "Untitled conversation"}</span>
          <span class="text-xs opacity-50">
            deleted {Calendar.strftime(conversation.deleted_at, "%Y-%m-%d %H:%M")}
          </span>
          <button
            :if={@can_edit}
            class="btn btn-ghost btn-xs"
            phx-click="restore_conversation"
            phx-value-conversation-id={conversation.id}
          >
            Restore
          </button>
          <button
            :if={@can_edit}
            class="btn btn-ghost btn-xs text-error"
            phx-click="purge_conversation"
            phx-value-conversation-id={conversation.id}
            data-confirm="Permanently delete this conversation now? No undo."
          >
            Purge now
          </button>
        </p>
      </div>

      <p :if={@conversations == []} class="text-sm opacity-60">No conversations yet.</p>

      <form :if={@all_labels != []} phx-change="filter_label" id="label-filter" class="w-fit">
        <select name="label" class="select select-bordered select-sm">
          <option value="">All labels</option>
          <option :for={label <- @all_labels} value={label} selected={@label_filter == label}>
            {label}
          </option>
        </select>
      </form>

      <div
        :if={@can_edit and @selected_conversation_ids != MapSet.new()}
        class="flex flex-wrap items-center gap-2 rounded-box bg-base-200/60 px-3 py-2"
        id="bulk-conversation-bar"
      >
        <span class="text-xs font-semibold">
          {MapSet.size(@selected_conversation_ids)} selected
        </span>
        <form phx-submit="bulk_label_conversations" class="flex gap-1" id="bulk-label-form">
          <input
            type="text"
            name="labels"
            placeholder="labels, comma-separated"
            class="input input-bordered input-xs w-48"
          />
          <button class="btn btn-outline btn-xs">Label</button>
        </form>
        <button
          class="btn btn-outline btn-xs text-error"
          phx-click="bulk_delete_conversations"
          data-confirm="Move the selected conversations to the trash?"
        >
          Delete
        </button>
        <button class="btn btn-ghost btn-xs" phx-click="clear_conversation_selection">
          Clear
        </button>
      </div>

      <div
        :for={conversation <- @conversations}
        :if={@label_filter == nil or @label_filter in conversation.labels}
        class="card border border-base-200"
      >
        <div class="flex items-center">
          <input
            :if={@can_edit}
            type="checkbox"
            class="checkbox checkbox-xs ml-3"
            checked={MapSet.member?(@selected_conversation_ids, conversation.id)}
            phx-click="toggle_conversation_select"
            phx-value-conversation-id={conversation.id}
            id={"conversation-select-#{conversation.id}"}
          />
          <button
            type="button"
            class="flex-1 flex items-center gap-3 px-4 py-3 text-left hover:bg-base-200/60 min-w-0"
            phx-click="select"
            phx-value-conversation-id={conversation.id}
          >
            <span class="font-semibold text-sm">
              {conversation.title || "Untitled conversation"}
            </span>
            <span
              :if={conversation.visitor_name || conversation.visitor_email}
              class="badge badge-outline badge-sm"
              title="Visitor-provided identity"
            >
              {[conversation.visitor_name, conversation.visitor_email]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" · ")}
            </span>
            <span :if={conversation.end_user_ref} class="badge badge-ghost badge-sm font-mono">
              {conversation.end_user_ref}
            </span>
            <span :for={label <- conversation.labels} class="badge badge-outline badge-sm">
              {label}
            </span>
            <span
              :if={conversation.handoff_requested_at}
              class="badge badge-warning badge-sm"
              title="Visitor asked for a human"
            >
              handoff
            </span>
            <span class="ml-auto text-xs opacity-60">
              {Calendar.strftime(conversation.inserted_at, "%Y-%m-%d %H:%M")}
            </span>
          </button>
        </div>

        <div :if={@selected_id == conversation.id} class="border-t border-base-200 p-4 space-y-2">
          <p :if={@conversation_usage} class="text-xs opacity-70" id="conversation-usage">
            <span class="font-semibold">This conversation:</span>
            {@conversation_usage.input_tokens + @conversation_usage.output_tokens} tokens
            ({@conversation_usage.input_tokens} in / {@conversation_usage.output_tokens} out)
            <span :if={@conversation_usage.cost > 0}>
              · ~${:erlang.float_to_binary(@conversation_usage.cost * 1.0, decimals: 4)} est.
            </span>
          </p>
          <div
            :if={conversation.summary}
            class="rounded-box bg-base-200/60 p-3 text-sm"
            id={"summary-#{conversation.id}"}
          >
            <p class="text-xs font-semibold opacity-70 mb-1">
              <.icon name="hero-book-open" class="size-3 inline" />
              Rolling memory (what the model carries forward)
            </p>
            <p class="whitespace-pre-wrap">{conversation.summary}</p>
          </div>
          <form
            :if={@can_edit}
            phx-submit="set_labels"
            class="flex gap-2 items-center"
            id={"labels-#{conversation.id}"}
          >
            <input type="hidden" name="conversation-id" value={conversation.id} />
            <input
              type="text"
              name="labels"
              value={Enum.join(conversation.labels, ", ")}
              placeholder="labels, comma-separated (billing, vip, …)"
              class="input input-bordered input-xs w-72"
              autocomplete="off"
            />
            <button class="btn btn-ghost btn-xs">Save labels</button>
          </form>
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

  defp format_sla(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_sla(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_sla(seconds), do: "#{Float.round(seconds / 3600, 1)}h"
end
