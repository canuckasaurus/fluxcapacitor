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
    App
    |> Repo.scoped(scope)
    |> where([a], is_nil(a.deleted_at))
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  def get_app(%Scope{} = scope, id) do
    App
    |> where(id: ^id)
    |> where([a], is_nil(a.deleted_at))
    |> Repo.scoped(scope)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      app -> app
    end
  end

  @doc "Trashed apps, newest deletion first."
  def list_trashed_apps(%Scope{} = scope) do
    App
    |> Repo.scoped(scope)
    |> where([a], not is_nil(a.deleted_at))
    |> order_by([a], desc: a.deleted_at)
    |> Repo.all()
  end

  def create_app(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         {:ok, app} <-
           %App{workspace_id: Scope.workspace_id(scope), created_by_id: Scope.account_id(scope)}
           |> App.changeset(attrs)
           |> Repo.insert() do
      Flux.Audit.record(scope, "app.create", resource: app, metadata: %{"name" => app.name})
      {:ok, app}
    end
  end

  @doc "Soft delete: the app moves to the trash (30-day purge, restorable)."
  def delete_app(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, trashed} <-
           app
           |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second), site_enabled: false)
           |> Repo.update() do
      Flux.Audit.record(scope, "app.trash", resource: app, metadata: %{"name" => app.name})
      {:ok, trashed}
    end
  end

  def restore_app(%Scope{} = scope, app_id) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         %App{} = app <-
           Repo.one(Repo.scoped(where(App, id: ^app_id), scope)) || {:error, :not_found},
         {:ok, restored} <- app |> Ecto.Changeset.change(deleted_at: nil) |> Repo.update() do
      Flux.Audit.record(scope, "app.restore", resource: app, metadata: %{"name" => app.name})
      {:ok, restored}
    end
  end

  @doc "Hard delete from the trash — gone for good."
  def purge_app(%Scope{} = scope, app_id) do
    with :ok <- RBAC.authorize(scope, :app_delete),
         %App{deleted_at: %DateTime{}} = app <-
           Repo.one(Repo.scoped(where(App, id: ^app_id), scope)) || {:error, :not_found},
         {:ok, deleted} <- Repo.delete(app) do
      Flux.Audit.record(scope, "app.purge", resource: app, metadata: %{"name" => app.name})
      {:ok, deleted}
    else
      %App{} -> {:error, :not_trashed}
      error -> error
    end
  end

  def update_app(%Scope{} = scope, %App{} = app, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      app |> App.changeset(attrs) |> Repo.update()
    end
  end

  ## Site publishing

  @doc """
  Publishes the app at a public URL (`/site/:token`). The token is minted
  once and survives disable/enable so the public URL stays stable.
  """
  def enable_site(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      token =
        app.site_token ||
          "site_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      with {:ok, updated} <-
             app
             |> Ecto.Changeset.change(site_token: token, site_enabled: true)
             |> Repo.update() do
        Flux.Audit.record(scope, "app.site_enable", resource: app)
        {:ok, updated}
      end
    end
  end

  def disable_site(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, updated} <- app |> Ecto.Changeset.change(site_enabled: false) |> Repo.update() do
      Flux.Audit.record(scope, "app.site_disable", resource: app)
      {:ok, updated}
    end
  end

  @doc "Resolves a public site token to its app; the token is the authorization."
  def get_app_by_site_token("site_" <> _rest = token) do
    case Repo.get_by(App, [site_token: token], skip_workspace_guard: true) do
      %App{site_enabled: true, deleted_at: nil} = app -> {:ok, app}
      _disabled_trashed_or_missing -> {:error, :not_found}
    end
  end

  def get_app_by_site_token(_other), do: {:error, :not_found}

  @doc "A workspace-only scope for anonymous public-site visitors."
  def site_scope(%App{} = app) do
    %Scope{
      account: nil,
      membership: nil,
      workspace: %Flux.Accounts.Workspace{id: app.workspace_id}
    }
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

  @doc "The visitor's most recent conversation with an app, or nil."
  def latest_conversation(%Scope{} = scope, app_id, end_user_ref)
      when is_binary(end_user_ref) and end_user_ref != "" do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and c.end_user_ref == ^end_user_ref)
    |> where([c], is_nil(c.deleted_at))
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(1)
    |> Repo.one()
  end

  def latest_conversation(%Scope{}, _app_id, _end_user_ref), do: nil

  @doc "All of a visitor's conversations with an app, newest first."
  def visitor_conversations(scope, app_id, end_user_ref, limit \\ 10)

  def visitor_conversations(%Scope{} = scope, app_id, end_user_ref, limit)
      when is_binary(end_user_ref) and end_user_ref != "" do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and c.end_user_ref == ^end_user_ref)
    |> where([c], is_nil(c.deleted_at))
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def visitor_conversations(%Scope{}, _app_id, _end_user_ref, _limit), do: []

  @doc "Copies an app's configuration into a new '(copy)' app — unpublished."
  def duplicate_app(%Scope{} = scope, %App{} = app) do
    create_app(scope, %{
      "name" => app.name <> " (copy)",
      "description" => app.description,
      "mode" => to_string(app.mode),
      "workflow_id" => app.workflow_id,
      "provider_plugin_id" => app.provider_plugin_id,
      "model" => app.model,
      "fallback_provider_plugin_id" => app.fallback_provider_plugin_id,
      "fallback_model" => app.fallback_model,
      "system_prompt" => app.system_prompt,
      "prompt_template" => app.prompt_template,
      "input_form" => app.input_form,
      "params" => app.params,
      "opening_statement" => app.opening_statement,
      "suggested_questions" => app.suggested_questions,
      "daily_token_limit" => app.daily_token_limit,
      "suggest_followups" => app.suggest_followups,
      "annotation_threshold" => app.annotation_threshold,
      "site_theme" => app.site_theme
    })
  end

  @doc "Replaces a conversation's labels (trimmed, deduped, max 10)."
  def set_conversation_labels(%Scope{} = scope, conversation_id, labels) when is_list(labels) do
    labels =
      labels
      |> Enum.map(&String.trim(to_string(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(10)

    case get_conversation(scope, conversation_id) do
      %Conversation{} = conversation ->
        conversation |> Ecto.Changeset.change(labels: labels) |> Repo.update()

      error ->
        error
    end
  end

  @doc "Every label in use across an app's conversations (filter chips)."
  def conversation_labels(%Scope{} = scope, app_id) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id)
    |> select([c], c.labels)
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  A/B comparison for a chat app's model test: replies, feedback, and
  tokens per variant over the recent history (variant "b" is stamped
  on the reply's usage; everything else is the primary).
  """
  def app_ab_stats(%Scope{} = scope, app_id, limit \\ 1_000) do
    Message
    |> Repo.scoped(scope)
    |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
    |> where([m, c], c.app_id == ^app_id and m.role == :assistant and m.status == :completed)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> select([m], %{usage: m.usage, feedback: m.feedback})
    |> Repo.all()
    |> Enum.reduce(
      %{
        "a" => %{replies: 0, likes: 0, dislikes: 0, tokens: 0},
        "b" => %{replies: 0, likes: 0, dislikes: 0, tokens: 0}
      },
      fn message, acc ->
        variant = (message.usage["variant"] == "b" && "b") || "a"

        Map.update!(acc, variant, fn stats ->
          %{
            replies: stats.replies + 1,
            likes: stats.likes + ((message.feedback == :like && 1) || 0),
            dislikes: stats.dislikes + ((message.feedback == :dislike && 1) || 0),
            tokens:
              stats.tokens + (message.usage["input_tokens"] || 0) +
                (message.usage["output_tokens"] || 0)
          }
        end)
      end
    )
  end

  ## Human handoff

  @doc "A visitor asked for a human: flag the conversation and tell the team."
  def request_handoff(%Scope{} = scope, %App{} = app, conversation_id) do
    case get_conversation(scope, conversation_id) do
      %Conversation{handoff_requested_at: nil} = conversation ->
        {:ok, flagged} =
          conversation
          |> Ecto.Changeset.change(handoff_requested_at: DateTime.utc_now(:second))
          |> Repo.update()

        Flux.Notifications.notify(
          app.workspace_id,
          "handoff",
          "A visitor asked for a human in #{app.name}.",
          "/console/apps/#{app.id}/monitor"
        )

        {:ok, flagged}

      %Conversation{} = already_flagged ->
        {:ok, already_flagged}

      error ->
        error
    end
  end

  @doc """
  A teammate answers from the console: inserts a completed assistant
  message (marked human), clears the handoff flag, and broadcasts on the
  conversation topic so an open site chat sees it live.
  """
  def human_reply(%Scope{} = scope, conversation_id, content)
      when is_binary(content) and content != "" do
    with %Conversation{} = conversation <- get_conversation(scope, conversation_id) do
      message =
        Repo.insert!(%Message{
          workspace_id: conversation.workspace_id,
          conversation_id: conversation.id,
          role: :assistant,
          content: content,
          status: :completed,
          usage: %{"human" => true, "author" => (scope.account && scope.account.email) || ""}
        })

      {:ok, conversation} =
        conversation
        |> Ecto.Changeset.change(handoff_requested_at: nil)
        |> Repo.update()

      Phoenix.PubSub.broadcast(
        Flux.PubSub,
        conversation_topic(conversation.id),
        {:human_reply, message}
      )

      {:ok, message}
    end
  end

  @doc """
  Per-visitor rollup for the monitoring page: conversations, messages,
  tokens, and feedback per `end_user_ref`, most recently seen first.
  """
  def visitor_stats(%Scope{} = scope, app_id, limit \\ 20) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and not is_nil(c.end_user_ref) and is_nil(c.deleted_at))
    |> join(:left, [c], m in Message, on: m.conversation_id == c.id)
    |> group_by([c], c.end_user_ref)
    |> select([c, m], %{
      ref: c.end_user_ref,
      conversations: count(c.id, :distinct),
      messages: count(m.id),
      tokens:
        fragment(
          "coalesce(sum(coalesce((? ->> 'input_tokens')::bigint, 0) + coalesce((? ->> 'output_tokens')::bigint, 0)), 0)",
          m.usage,
          m.usage
        ),
      likes: fragment("count(*) filter (where ? = 'like')", m.feedback),
      dislikes: fragment("count(*) filter (where ? = 'dislike')", m.feedback),
      last_seen: max(m.inserted_at)
    })
    |> order_by([c, m], desc: max(m.inserted_at))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Conversations currently waiting on a human, oldest wait first."
  def handoff_queue(%Scope{} = scope, app_id) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and not is_nil(c.handoff_requested_at))
    |> where([c], is_nil(c.deleted_at))
    |> order_by([c], asc: c.handoff_requested_at)
    |> Repo.all()
  end

  def conversation_topic(conversation_id), do: "conversation:#{conversation_id}"

  def subscribe_conversation(conversation_id),
    do: Phoenix.PubSub.subscribe(Flux.PubSub, conversation_topic(conversation_id))

  @doc "Console-originated conversations (no end-user ref), newest first."
  def console_conversations(%Scope{} = scope, app_id, limit \\ 15) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and is_nil(c.end_user_ref))
    |> where([c], is_nil(c.deleted_at))
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Console conversations whose title or messages match `q` (ILIKE)."
  def search_conversations(%Scope{} = scope, app_id, q, limit \\ 15) do
    pattern = "%" <> String.replace(to_string(q), ~r/[%_\\]/, "") <> "%"
    workspace_id = Scope.workspace_id(scope)

    matching =
      from(m in Message,
        where: m.workspace_id == ^workspace_id and ilike(m.content, ^pattern),
        select: m.conversation_id
      )

    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and is_nil(c.end_user_ref) and is_nil(c.deleted_at))
    |> where([c], ilike(c.title, ^pattern) or c.id in subquery(matching))
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_conversations(%Scope{} = scope, app_id, limit \\ 20) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and is_nil(c.deleted_at))
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

  @doc "Soft delete: the conversation moves to the trash (30-day purge, restorable)."
  def delete_conversation(%Scope{} = scope, conversation_id) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.id == ^conversation_id and is_nil(c.deleted_at))
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      conversation ->
        conversation
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
        |> Repo.update()
    end
  end

  @doc "Trashed conversations for an app, newest deletion first."
  def list_trashed_conversations(%Scope{} = scope, app_id, limit \\ 20) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and not is_nil(c.deleted_at))
    |> order_by([c], desc: c.deleted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def restore_conversation(%Scope{} = scope, conversation_id) do
    case Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) do
      nil ->
        {:error, :not_found}

      conversation ->
        conversation |> Ecto.Changeset.change(deleted_at: nil) |> Repo.update()
    end
  end

  @doc "Records end-user feedback (like/dislike/nil to clear) on a message."
  def set_feedback(%Scope{} = scope, message_id, rating) when rating in [:like, :dislike, nil] do
    case Repo.one(Repo.scoped(where(Message, id: ^message_id), scope)) do
      nil ->
        {:error, :not_found}

      message ->
        with {:ok, updated} <- message |> Ecto.Changeset.change(feedback: rating) |> Repo.update() do
          if rating != nil do
            Flux.Webhooks.dispatch(updated.workspace_id, "feedback.created", %{
              "message_id" => updated.id,
              "conversation_id" => updated.conversation_id,
              "feedback" => to_string(rating)
            })
          end

          {:ok, updated}
        end
    end
  end

  @topic_stopwords MapSet.new(~w(the a an is are was were be been am and or but if then else
                     for nor not no yes on in at by to from of with as so do does did done can
                     could will would should may might must i we you they he she it its this
                     that these those my your our their his her me us them what when where why
                     how which who whom about into over under again please help need want know
                     get make))

  @doc """
  What people actually ask: recent user messages greedily clustered by
  token overlap (Jaccard on stopword-filtered words), largest clusters
  first with a top-terms name and an example. Deterministic — no model
  calls, works on any provider.
  """
  def topic_clusters(%Scope{} = scope, app_id, opts \\ []) do
    sample = Keyword.get(opts, :sample, 200)
    max_clusters = Keyword.get(opts, :max_clusters, 8)

    contents =
      Message
      |> Repo.scoped(scope)
      |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
      |> where([m, c], c.app_id == ^app_id and m.role == :user)
      |> order_by([m], desc: m.seq)
      |> limit(^sample)
      |> select([m], m.content)
      |> Repo.all()

    contents
    |> Enum.reduce([], fn content, clusters ->
      tokens = topic_tokens(content)

      if MapSet.size(tokens) == 0 do
        clusters
      else
        case Enum.split_while(clusters, &(jaccard(&1.seed, tokens) < 0.3)) do
          {_misses, []} ->
            [%{seed: tokens, count: 1, examples: [content], terms: tokens} | clusters]

          {before, [cluster | rest]} ->
            updated = %{
              cluster
              | count: cluster.count + 1,
                examples: Enum.take([content | cluster.examples], 3),
                terms: MapSet.union(cluster.terms, tokens)
            }

            before ++ [updated | rest]
        end
      end
    end)
    |> Enum.sort_by(&(-&1.count))
    |> Enum.take(max_clusters)
    |> Enum.map(fn cluster ->
      %{
        name: cluster.seed |> MapSet.to_list() |> Enum.sort() |> Enum.take(3) |> Enum.join(" · "),
        count: cluster.count,
        example: List.first(cluster.examples)
      }
    end)
  end

  defp topic_tokens(content) do
    content
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or MapSet.member?(@topic_stopwords, &1)))
    |> MapSet.new()
  end

  defp jaccard(a, b) do
    union = MapSet.union(a, b) |> MapSet.size()
    if union == 0, do: 0.0, else: MapSet.intersection(a, b) |> MapSet.size() |> Kernel./(union)
  end

  @doc "Messages matching `query` across an app's conversations, newest first."
  def search_messages(%Scope{} = scope, app_id, query, limit \\ 20) do
    case String.trim(to_string(query)) do
      "" ->
        []

      trimmed ->
        pattern = "%" <> String.replace(trimmed, ~r/[\\%_]/, fn c -> "\\" <> c end) <> "%"

        Message
        |> Repo.scoped(scope)
        |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
        |> where([m, c], c.app_id == ^app_id and ilike(m.content, ^pattern))
        |> order_by([m], desc: m.seq)
        |> limit(^limit)
        |> select([m, c], %{message: m, conversation: c})
        |> Repo.all()
    end
  end

  def list_messages(%Scope{} = scope, conversation_id) do
    Message
    |> Repo.scoped(scope)
    |> where([m], m.conversation_id == ^conversation_id)
    |> order_by([m], asc: m.seq)
    |> Repo.all()
  end

  @doc """
  Persists the user message, creates a streaming assistant placeholder,
  subscribes the calling process to the message topic (so no chunk can be
  missed), and starts generation. Returns
  `{:ok, user_message, assistant_message}`.
  """
  def send_message(scope, app, conversation, content, opts \\ [])

  def send_message(%Scope{} = scope, %App{} = app, %Conversation{} = conversation, content, opts)
      when is_binary(content) do
    if quota_exceeded?(app) do
      {:error, :quota_exceeded}
    else
      # Redact-mode guardrails mask the stored message too — the model
      # and the transcript both see the sanitized text.
      case Flux.Guardrails.sanitize_input(app.workspace_id, content, "chat (#{app.name})") do
        {:ok, content} -> do_send_message(scope, app, conversation, content, opts)
        {:error, :guardrail} -> {:error, :guardrail}
      end
    end
  end

  defp do_send_message(scope, app, conversation, content, opts) do
    workspace_id = Scope.workspace_id(scope)

    files =
      for %Flux.Chat.UploadedFile{} = file <- Keyword.get(opts, :files, []) do
        %{"id" => file.id, "name" => file.name, "content_type" => file.content_type}
      end

    user_message =
      Repo.insert!(%Message{
        workspace_id: workspace_id,
        conversation_id: conversation.id,
        role: :user,
        content: content,
        files: files
      })

    # Untitled conversations take their first question as the title
    # (manual renames are never overwritten).
    if conversation.title in [nil, ""] do
      from(c in Conversation,
        where: c.id == ^conversation.id and c.workspace_id == ^workspace_id and is_nil(c.title)
      )
      |> Repo.update_all(set: [title: derive_title(content)])
    end

    assistant_message =
      Repo.insert!(%Message{
        workspace_id: workspace_id,
        conversation_id: conversation.id,
        role: :assistant,
        status: :streaming
      })

    :ok = subscribe(assistant_message.id)

    history = list_messages(scope, conversation.id)
    annotation = match_annotation(app, content)

    {:ok, _pid} =
      Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
        Registry.register(Flux.GenerationRegistry, assistant_message.id, nil)

        if annotation do
          answer_from_annotation(annotation, assistant_message)
        else
          generate(app, history, assistant_message)
        end
      end)

    {:ok, user_message, assistant_message}
  end

  @doc """
  Discards the conversation's last assistant reply and streams a fresh
  one from the same user message. Returns `{:ok, assistant_message}`
  (subscribe to its id for chunks) or `{:error, :nothing_to_regenerate}`.
  """
  def regenerate(%Scope{} = scope, %App{} = app, %Conversation{} = conversation) do
    workspace_id = Scope.workspace_id(scope)

    with :ok <- if(quota_exceeded?(app), do: {:error, :quota_exceeded}, else: :ok),
         [%Message{role: :assistant, status: status} = last | earlier]
         when status != :streaming <-
           scope |> list_messages(conversation.id) |> Enum.reverse(),
         %Message{role: :user} = user_message <-
           Enum.find(earlier, &(&1.role == :user)) || {:error, :nothing_to_regenerate} do
      Repo.delete!(last)

      assistant_message =
        Repo.insert!(%Message{
          workspace_id: workspace_id,
          conversation_id: conversation.id,
          role: :assistant,
          status: :streaming
        })

      :ok = subscribe(assistant_message.id)

      history = list_messages(scope, conversation.id)
      annotation = match_annotation(app, user_message.content)

      {:ok, _pid} =
        Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
          Registry.register(Flux.GenerationRegistry, assistant_message.id, nil)

          if annotation do
            answer_from_annotation(annotation, assistant_message)
          else
            generate(app, history, assistant_message)
          end
        end)

      {:ok, assistant_message}
    else
      {:error, reason} -> {:error, reason}
      _no_reply_yet -> {:error, :nothing_to_regenerate}
    end
  end

  defp derive_title(content) do
    clean = content |> String.replace(~r/\s+/, " ") |> String.trim()

    cond do
      clean == "" -> nil
      String.length(clean) <= 60 -> clean
      true -> (clean |> String.slice(0, 59) |> String.trim_trailing()) <> "…"
    end
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

  @doc """
  Up to three short follow-up questions for the conversation's recent
  turns — the chips under a finished reply when the app opts in. Uses
  the app's own model (or the workspace default); empty on any failure.
  """
  def follow_up_suggestions(%Scope{} = scope, %App{} = app, conversation_id) do
    transcript =
      scope
      |> list_messages(conversation_id)
      |> Enum.filter(&(&1.status == :completed or &1.role == :user))
      |> Enum.take(-6)
      |> Enum.map_join("\n", &"#{&1.role}: #{&1.content}")

    {provider, model} =
      case {app.provider_plugin_id, Providers.default_model_for_workspace(app.workspace_id)} do
        {nil, %{"provider_plugin_id" => provider, "model" => model}} -> {provider, model}
        {nil, _none} -> {nil, nil}
        {provider, _default} -> {provider, app.model}
      end

    if provider == nil or transcript == "" do
      []
    else
      request = %Flux.Plugin.ModelProvider.Request{
        model: model,
        messages: [
          %{
            role: :system,
            content:
              "You suggest follow-up questions. Reply with up to three short " <>
                "questions the user might ask next, one per line, no numbering."
          },
          %{role: :user, content: "Conversation so far:\n#{transcript}"}
        ],
        params: %{}
      }

      credentials =
        case Providers.fetch_config(app.workspace_id, provider) do
          {:ok, config} -> config
          {:error, :not_configured} -> %{}
        end

      case runtime().invoke_llm(provider, credentials, request, fn _chunk -> :ok end) do
        {:ok, result} ->
          result.content
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&(&1 |> String.replace(~r/^[\s\-\*\d\.\)]+/, "") |> String.trim()))
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(3)

        {:error, _reason} ->
          []
      end
    end
  end

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

  @doc "Fetches an uploaded file in the scope's workspace, or nil."
  def get_uploaded_file(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Flux.Chat.UploadedFile, id: ^id), scope))
  end

  @doc "Whether the app's daily token budget (input+output, UTC day) is spent."
  def quota_exceeded?(%App{daily_token_limit: nil}), do: false

  def quota_exceeded?(%App{daily_token_limit: limit} = app) do
    today = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    used =
      Message
      |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
      |> where([m, c], c.app_id == ^app.id and m.workspace_id == ^app.workspace_id)
      |> where([m], m.role == :assistant and m.inserted_at >= ^today)
      |> select([m], %{
        total:
          sum(
            fragment(
              "coalesce((? ->> 'input_tokens')::bigint, 0) + coalesce((? ->> 'output_tokens')::bigint, 0)",
              m.usage,
              m.usage
            )
          )
      })
      |> Repo.one()

    decimal_to_int(used.total) >= limit
  end

  ## Annotations

  alias Flux.Chat.Annotation

  @doc "Annotations for an app, newest first."
  def list_annotations(%Scope{} = scope, app_id) do
    Annotation
    |> Repo.scoped(scope)
    |> where([a], a.app_id == ^app_id)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> Repo.all()
  end

  @doc """
  Bulk-imports annotations from `[question, answer]` rows (the CSV
  paste box on monitoring). Returns `{:ok, imported_count}` — blank or
  malformed rows skip rather than failing the batch.
  """
  def import_annotations(%Scope{} = scope, %App{} = app, rows) when is_list(rows) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      imported =
        Enum.count(rows, fn
          [question, answer | _rest] ->
            match?(
              {:ok, _annotation},
              create_annotation(scope, app, %{
                question: to_string(question),
                answer: to_string(answer)
              })
            )

          _short_row ->
            false
        end)

      {:ok, imported}
    end
  end

  @doc """
  Exports an app's curated conversations as OpenAI chat-format JSONL for
  fine-tuning: one `{"messages": [...]}` object per line, built from
  liked assistant replies (`filter: :liked`, the default) or every
  completed reply (`filter: :all`), plus the app's enabled annotations.
  The app's system prompt rides along when set.
  """
  def export_finetune(%Scope{} = scope, app_id, opts \\ []) do
    filter = Keyword.get(opts, :filter, :liked)

    with :ok <- RBAC.authorize(scope, :app_import_export_dsl),
         %App{} = app <- get_app(scope, app_id) do
      lines = finetune_pairs(scope, app, filter) ++ finetune_annotation_lines(scope, app)
      {:ok, Enum.map_join(lines, "\n", &Jason.encode!/1)}
    end
  end

  defp finetune_pairs(scope, app, filter) do
    Message
    |> Repo.scoped(scope)
    |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
    |> where([m, c], c.app_id == ^app.id and m.status == :completed)
    |> order_by([m], asc: m.conversation_id, asc: m.seq)
    |> Repo.all()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [question, reply] ->
      question.role == :user and reply.role == :assistant and
        question.conversation_id == reply.conversation_id and
        finetune_keep?(reply, filter)
    end)
    |> Enum.map(fn [question, reply] ->
      finetune_line(app, question.content, reply.content)
    end)
  end

  defp finetune_keep?(reply, :liked), do: reply.feedback == :like
  defp finetune_keep?(_reply, :all), do: true

  defp finetune_annotation_lines(scope, app) do
    scope
    |> list_annotations(app.id)
    |> Enum.filter(& &1.enabled)
    |> Enum.map(&finetune_line(app, &1.question, &1.answer))
  end

  defp finetune_line(app, question, reply) do
    system =
      case app.system_prompt do
        prompt when is_binary(prompt) and prompt != "" ->
          [%{"role" => "system", "content" => prompt}]

        _absent ->
          []
      end

    %{
      "messages" =>
        system ++
          [
            %{"role" => "user", "content" => question},
            %{"role" => "assistant", "content" => String.trim(reply)}
          ]
    }
  end

  @doc "Creates a canonical question→answer pair for the app."
  def create_annotation(%Scope{} = scope, %App{} = app, %{question: question, answer: answer})
      when is_binary(question) and is_binary(answer) do
    with :ok <- Flux.Features.authorize(scope, :annotations),
         :ok <- RBAC.authorize(scope, :app_edit),
         true <- (String.trim(question) != "" and String.trim(answer) != "") || {:error, :empty} do
      question = String.trim(question)

      annotation =
        Repo.insert!(
          struct!(
            %Annotation{
              workspace_id: app.workspace_id,
              app_id: app.id,
              question: question,
              answer: String.trim(answer)
            },
            annotation_embedding(scope, app.workspace_id, question)
          )
        )

      Flux.Audit.record(scope, "annotation.create",
        resource_type: "annotation",
        resource_id: annotation.id,
        metadata: %{"app_id" => app.id}
      )

      {:ok, annotation}
    end
  end

  # Embed the question with the workspace's first embedding model so
  # similarity matching can work; without one, exact matching still does.
  defp annotation_embedding(scope, workspace_id, question) do
    with %{plugin_id: plugin_id, model: model} <-
           Enum.find(Providers.available_models(scope), &(&1.model.type == :text_embedding)),
         {:ok, [vector]} <-
           Providers.embed_texts(workspace_id, plugin_id, model.name, [question]) do
      %{embedding: vector, embedding_plugin_id: plugin_id, embedding_model: model.name}
    else
      _unavailable -> %{}
    end
  end

  @doc "Promotes a rated assistant reply into an annotation (feedback review)."
  def annotate_from_message(%Scope{} = scope, %App{} = app, message_id) do
    with %Message{role: :assistant} = message <-
           Repo.one(Repo.scoped(where(Message, id: ^message_id), scope)) ||
             {:error, :not_found},
         question when is_binary(question) <-
           preceding_question(scope, message) || {:error, :no_question} do
      create_annotation(scope, app, %{question: question, answer: message.content})
    else
      %Message{} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_annotation(%Scope{} = scope, annotation_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Annotation{} = annotation <-
           Repo.one(Repo.scoped(where(Annotation, id: ^annotation_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(annotation)
    end
  end

  # Exact (normalized) match first — free — then, when the app sets an
  # annotation_threshold, embedding similarity against annotations that
  # carry a vector (grouped by their embedding model).
  defp match_annotation(app, content) do
    normalized = normalize_question(content)

    if normalized == "" do
      nil
    else
      annotations =
        Annotation
        |> where([a], a.workspace_id == ^app.workspace_id and a.app_id == ^app.id and a.enabled)
        |> Repo.all()

      Enum.find(annotations, &(normalize_question(&1.question) == normalized)) ||
        fuzzy_match(app, content, annotations)
    end
  end

  defp fuzzy_match(%App{annotation_threshold: threshold} = app, content, annotations)
       when is_float(threshold) do
    annotations
    |> Enum.filter(&is_list(&1.embedding))
    |> Enum.group_by(&{&1.embedding_plugin_id, &1.embedding_model})
    |> Enum.flat_map(fn {{plugin_id, model}, group} ->
      case Providers.embed_texts(app.workspace_id, plugin_id, model, [content]) do
        {:ok, [query_vector]} ->
          Enum.map(group, &{&1, cosine(query_vector, &1.embedding)})

        {:error, _reason} ->
          []
      end
    end)
    |> Enum.max_by(fn {_annotation, score} -> score end, fn -> nil end)
    |> case do
      {annotation, score} when score >= threshold -> annotation
      _below_or_none -> nil
    end
  end

  defp fuzzy_match(_app, _content, _annotations), do: nil

  defp cosine(a, b) when length(a) == length(b) do
    {dot, mag_a, mag_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, ma, mb} ->
        {dot + x * y, ma + x * x, mb + y * y}
      end)

    denominator = :math.sqrt(mag_a) * :math.sqrt(mag_b)
    if denominator == 0.0, do: 0.0, else: dot / denominator
  end

  defp cosine(_a, _b), do: 0.0

  defp normalize_question(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[?!.\s]+$/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The annotation answers instead of the model: streamed as one chunk so
  # every consumer (console, sites, /v1 SSE) behaves identically.
  defp answer_from_annotation(annotation, assistant_message) do
    Flux.StreamBuffers.append(assistant_message.id, annotation.answer)

    Phoenix.PubSub.broadcast(
      Flux.PubSub,
      topic(assistant_message.id),
      {:chunk, annotation.answer}
    )

    from(a in Annotation, where: a.id == ^annotation.id)
    |> Repo.update_all([inc: [hit_count: 1]], skip_workspace_guard: true)

    finalize(assistant_message, :completed, annotation.answer, %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "annotation_id" => annotation.id
    })
  end

  @doc """
  Rated assistant messages for an app, newest first, each paired with the
  question that prompted it. `filter` is `:all`, `:like`, or `:dislike`.
  """
  def list_feedback(%Scope{} = scope, app_id, filter \\ :all, limit \\ 100) do
    messages =
      Message
      |> Repo.scoped(scope)
      |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
      |> where([m, c], c.app_id == ^app_id and not is_nil(m.feedback))
      |> then(fn query ->
        case filter do
          :like -> where(query, [m], m.feedback == :like)
          :dislike -> where(query, [m], m.feedback == :dislike)
          _all -> query
        end
      end)
      |> order_by([m], desc: m.inserted_at, desc: m.id)
      |> limit(^limit)
      |> Repo.all()

    # One query for every candidate question instead of one per rated reply.
    questions = user_messages_by_conversation(scope, messages)

    Enum.map(messages, fn message ->
      question =
        questions
        |> Map.get(message.conversation_id, [])
        |> Enum.filter(fn {seq, _content} -> seq < message.seq end)
        |> Enum.max_by(fn {seq, _content} -> seq end, fn -> nil end)
        |> case do
          {_seq, content} -> content
          nil -> nil
        end

      %{message: message, question: question}
    end)
  end

  defp user_messages_by_conversation(_scope, []), do: %{}

  defp user_messages_by_conversation(scope, messages) do
    conversation_ids = messages |> Enum.map(& &1.conversation_id) |> Enum.uniq()

    Message
    |> Repo.scoped(scope)
    |> where([m], m.conversation_id in ^conversation_ids and m.role == :user)
    |> select([m], {m.conversation_id, m.seq, m.content})
    |> Repo.all()
    |> Enum.group_by(
      fn {conversation_id, _seq, _content} -> conversation_id end,
      fn {_conversation_id, seq, content} -> {seq, content} end
    )
  end

  # The user turn right before the rated answer.
  defp preceding_question(scope, message) do
    Message
    |> Repo.scoped(scope)
    |> where([m], m.conversation_id == ^message.conversation_id and m.role == :user)
    |> where([m], m.seq < ^message.seq)
    |> order_by([m], desc: m.seq)
    |> limit(1)
    |> select([m], m.content)
    |> Repo.one()
  end

  @doc """
  Per-day quality rollups for an app: replies, likes, dislikes, and
  annotation hits (replies answered from the annotation library instead
  of the model) over the trailing `days`.
  """
  def quality_stats(%Scope{} = scope, app_id, days \\ 14) do
    since = DateTime.add(DateTime.utc_now(:second), -days, :day)

    Message
    |> Repo.scoped(scope)
    |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
    |> where([m, c], c.app_id == ^app_id and m.role == :assistant and m.inserted_at >= ^since)
    |> group_by([m], fragment("date(?)", m.inserted_at))
    |> order_by([m], desc: fragment("date(?)", m.inserted_at))
    |> select([m], %{
      day: fragment("date(?)", m.inserted_at),
      replies: count(m.id),
      likes: count(fragment("case when ? = 'like' then 1 end", m.feedback)),
      dislikes: count(fragment("case when ? = 'dislike' then 1 end", m.feedback)),
      annotation_hits: count(fragment("case when ? \\? 'annotation_id' then 1 end", m.usage))
    })
    |> Repo.all()
  end

  @doc """
  Per-day usage rollups for an app over the trailing `days`: assistant
  message count and token sums from the messages' usage maps.
  """
  def usage_stats(%Scope{} = scope, app_id, days \\ 14) do
    since = DateTime.add(DateTime.utc_now(:second), -days, :day)

    Message
    |> Repo.scoped(scope)
    |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
    |> where([m, c], c.app_id == ^app_id and m.role == :assistant)
    |> where([m], m.inserted_at >= ^since)
    |> group_by([m], fragment("date(?)", m.inserted_at))
    |> select([m], %{
      day: fragment("date(?)", m.inserted_at),
      messages: count(m.id),
      input_tokens: sum(fragment("coalesce((? ->> 'input_tokens')::bigint, 0)", m.usage)),
      output_tokens: sum(fragment("coalesce((? ->> 'output_tokens')::bigint, 0)", m.usage))
    })
    |> order_by([m], desc: fragment("date(?)", m.inserted_at))
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        row
        | input_tokens: decimal_to_int(row.input_tokens),
          output_tokens: decimal_to_int(row.output_tokens)
      }
    end)
  end

  defp decimal_to_int(nil), do: 0
  defp decimal_to_int(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp decimal_to_int(integer) when is_integer(integer), do: integer

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

  @doc """
  Mints an app token. `expires_in_days: nil` (default) is perpetual;
  an integer makes the token self-destruct after that many days —
  both lifetimes are deliberate, first-class choices.
  """
  def create_api_token(%Scope{} = scope, %App{} = app, opts \\ []) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management) do
      raw = "app-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      token =
        Repo.insert!(%ApiToken{
          workspace_id: Scope.workspace_id(scope),
          app_id: app.id,
          token_hash: :crypto.hash(:sha256, raw),
          prefix: String.slice(raw, 0, 12) <> "…",
          expires_at: token_expiry(opts[:expires_in_days])
        })

      Flux.Audit.record(scope, "api_token.create",
        resource: token,
        metadata: %{"app_id" => app.id, "prefix" => token.prefix}
      )

      {:ok, token, raw}
    end
  end

  @doc false
  def token_expiry(nil), do: nil

  def token_expiry(days) when is_integer(days) and days > 0,
    do: DateTime.add(DateTime.utc_now(:second), days, :day)

  @doc false
  def token_expired?(%ApiToken{expires_at: nil}), do: false

  def token_expired?(%ApiToken{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  def list_api_tokens(%Scope{} = scope, app_id) do
    ApiToken |> Repo.scoped(scope) |> where([t], t.app_id == ^app_id) |> Repo.all()
  end

  def revoke_api_token(%Scope{} = scope, token_id) do
    case Repo.one(Repo.scoped(where(ApiToken, id: ^token_id), scope)) do
      nil ->
        {:error, :not_found}

      token ->
        with {:ok, deleted} <- Repo.delete(token) do
          Flux.Audit.record(scope, "api_token.revoke",
            resource: token,
            metadata: %{"prefix" => token.prefix}
          )

          {:ok, deleted}
        end
    end
  end

  @doc """
  Mints a workspace-scoped `ws-…` token: no app or flux binding, made
  for the datasets/quality/models endpoints that only need a workspace.
  Same lifetime choices as the other kinds.
  """
  def create_workspace_token(%Scope{} = scope, opts \\ []) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management) do
      raw = "ws-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      token =
        Repo.insert!(%ApiToken{
          workspace_id: Scope.workspace_id(scope),
          token_hash: :crypto.hash(:sha256, raw),
          prefix: String.slice(raw, 0, 11) <> "…",
          expires_at: token_expiry(opts[:expires_in_days])
        })

      Flux.Audit.record(scope, "api_token.create",
        resource: token,
        metadata: %{"kind" => "workspace", "prefix" => token.prefix}
      )

      {:ok, token, raw}
    end
  end

  def list_workspace_tokens(%Scope{} = scope) do
    ApiToken
    |> Repo.scoped(scope)
    |> where([t], is_nil(t.app_id) and is_nil(t.workflow_id))
    |> Repo.all()
  end

  @doc "Resolves a raw `ws-…` token to its workspace id."
  def fetch_workspace_by_token("ws-" <> _rest = raw) do
    hash = :crypto.hash(:sha256, raw)

    case Repo.get_by(ApiToken, [token_hash: hash], skip_workspace_guard: true) do
      %ApiToken{app_id: nil, workflow_id: nil} = token ->
        if token_expired?(token) do
          {:error, :token_expired}
        else
          token
          |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
          |> Repo.update()

          {:ok, token.workspace_id, token}
        end

      _other ->
        {:error, :invalid_token}
    end
  end

  def fetch_workspace_by_token(_other), do: {:error, :invalid_token}

  @doc "Resolves a raw bearer token to `{app, token}`; touches last_used_at."
  def fetch_app_by_token("app-" <> _ = raw) do
    hash = :crypto.hash(:sha256, raw)

    # Token possession is the authorization; the lookup is cross-workspace.
    case Repo.get_by(ApiToken, [token_hash: hash], skip_workspace_guard: true) do
      nil ->
        {:error, :invalid_token}

      token ->
        cond do
          token_expired?(token) ->
            {:error, :token_expired}

          true ->
            token
            |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
            |> Repo.update()

            case Repo.get!(App, token.app_id, skip_workspace_guard: true) do
              %App{deleted_at: nil} = app -> {:ok, app, token}
              _trashed -> {:error, :invalid_token}
            end
        end
    end
  end

  def fetch_app_by_token(_other), do: {:error, :invalid_token}

  ## Generation internals

  # Chatflow: the turn is answered by the app's published flux. The
  # engine run streams through the run topic (this task subscribed via
  # start_run); we bridge chunks to the message topic, persist
  # conversation-variable writes, and finalize from the run outcome.
  defp generate(%App{mode: :advanced_chat} = app, history, assistant_message) do
    scope = site_scope(app)

    query =
      history
      |> Enum.reverse()
      |> Enum.find_value("", fn message ->
        message.role == :user && message.content
      end)

    conversation =
      Repo.get!(Conversation, assistant_message.conversation_id, skip_workspace_guard: true)

    with %Flux.Workflows.Workflow{deleted_at: nil} = workflow <-
           app.workflow_id &&
             Repo.get_by(Flux.Workflows.Workflow, [id: app.workflow_id],
               skip_workspace_guard: true
             ),
         %{} = version <- Flux.Workflows.serving_version(scope, workflow) do
      # The message is offered both as {{sys.query}} (chatflow convention)
      # and as the "query" start variable so the default starter graph
      # works as a chatflow unchanged. Prior completed turns arrive as
      # {{sys.history}} ("user: …\nassistant: …") for multi-turn memory —
      # with the same rolling summary folding direct-model apps get, so
      # long chatflow conversations stay inside the window too.
      {history, summary} = fold_history(app, conversation.id, history)
      history_text = chatflow_history(history)

      history_text =
        case summary do
          text when is_binary(text) and text != "" ->
            "summary of earlier turns: #{text}\n#{history_text}"

          _none ->
            history_text
        end

      {:ok, _run} =
        Flux.Workflows.start_run(scope, workflow, %{"query" => query},
          graph: version.graph,
          version: version.version,
          source: :api,
          sys: %{
            "query" => query,
            "conversation_id" => conversation.id,
            "history" => history_text,
            "turns" => div(Enum.count(history, &(&1.status == :completed)), 2)
          },
          conversation: conversation.variables || %{}
        )

      bridge_run(assistant_message, conversation, %{})
    else
      _missing ->
        fail_generation(assistant_message, "This app has no published flux to run.")
    end
  end

  defp generate(app, history, assistant_message) do
    {history, summary} = fold_history(app, assistant_message.conversation_id, history)

    # Model A/B: ab_split% of conversations (stable per conversation)
    # run the challenger; the reply's usage records which variant.
    {app, variant} = pick_ab_variant(app, assistant_message.conversation_id)

    request = %Flux.Plugin.ModelProvider.Request{
      model: app.model,
      messages: inject_summary(build_prompt(app, history), summary),
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
        Flux.ProviderHealth.record(app.provider_plugin_id, :ok)

        usage = %{
          "input_tokens" => result.usage.input_tokens,
          "output_tokens" => result.usage.output_tokens
        }

        usage =
          (variant == "b" &&
             Map.merge(usage, %{
               "variant" => "b",
               "model_used" => "#{app.provider_plugin_id}/#{app.model}"
             })) || usage

        finalize(assistant_message, :completed, result.content, usage)

      {:error, reason} ->
        Flux.ProviderHealth.record(app.provider_plugin_id, :error)
        generate_fallback(app, request, emit, assistant_message, reason)
    end
  end

  # ab_split% of conversations (stable by conversation id) swap in the
  # challenger model; everything downstream sees a normal app.
  defp pick_ab_variant(
         %App{ab_split: split, ab_provider_plugin_id: plugin, ab_model: model} = app,
         conversation_id
       )
       when is_integer(split) and split > 0 and is_binary(plugin) and plugin != "" and
              is_binary(model) and model != "" do
    if rem(:erlang.phash2(conversation_id), 100) < split do
      {%{app | provider_plugin_id: plugin, model: model}, "b"}
    else
      {app, "a"}
    end
  end

  defp pick_ab_variant(app, _conversation_id), do: {app, "a"}

  # A configured backup model gets one try when the primary errors; the
  # reply's usage records which model actually answered.
  defp generate_fallback(
         %App{fallback_provider_plugin_id: plugin, fallback_model: model} = app,
         request,
         emit,
         assistant_message,
         primary_reason
       )
       when is_binary(plugin) and plugin != "" and is_binary(model) and model != "" do
    credentials =
      case Providers.fetch_config(app.workspace_id, plugin) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    case runtime().invoke_llm(plugin, credentials, %{request | model: model}, emit) do
      {:ok, result} ->
        Flux.ProviderHealth.record(plugin, :ok)

        finalize(assistant_message, :completed, result.content, %{
          "input_tokens" => result.usage.input_tokens,
          "output_tokens" => result.usage.output_tokens,
          "model_used" => "#{plugin}/#{model}",
          "fallback_used" => true
        })

      {:error, _fallback_reason} ->
        # The primary's error is the honest one to surface.
        Flux.ProviderHealth.record(plugin, :error)
        generate_error(assistant_message, primary_reason)
    end
  end

  defp generate_fallback(_app, _request, _emit, assistant_message, reason) do
    generate_error(assistant_message, reason)
  end

  defp generate_error(assistant_message, reason) do
    Flux.StreamBuffers.delete(assistant_message.id)

    message =
      assistant_message
      |> Ecto.Changeset.change(status: :error, error: format_error(reason))
      |> Repo.update!()

    Phoenix.PubSub.broadcast(Flux.PubSub, topic(assistant_message.id), {:error, message})
    {:error, reason}
  end

  ## Rolling conversation memory

  # Long chats stay coherent instead of blowing the context window:
  # once the completed history outgrows the budget, older turns fold
  # into a maintained summary stored on the conversation. The summary
  # is incremental — already-folded turns are never re-summarized —
  # and a failed summarization falls back to the full history.
  @memory_budget_tokens 6_000
  @memory_keep_tokens 3_000

  defp fold_history(app, conversation_id, history) do
    completed = Enum.filter(history, &(&1.status == :completed or &1.role == :user))

    if estimate_tokens(completed) <= @memory_budget_tokens do
      {history, current_summary(conversation_id)}
    else
      {folded, kept} = split_for_memory(completed)
      conversation = Repo.get(Conversation, conversation_id, skip_workspace_guard: true)

      case update_summary(app, conversation, folded) do
        {:ok, summary} -> {kept, summary}
        :error -> {history, conversation && conversation.summary}
      end
    end
  end

  defp current_summary(conversation_id) do
    case Repo.get(Conversation, conversation_id, skip_workspace_guard: true) do
      %Conversation{summary: summary} -> summary
      _gone -> nil
    end
  end

  defp inject_summary(messages, summary) when is_binary(summary) and summary != "" do
    note = %{
      role: :system,
      content: "Summary of the conversation so far (older turns):\n" <> summary
    }

    case messages do
      [%{role: :system} = system | rest] -> [system, note | rest]
      rest -> [note | rest]
    end
  end

  defp inject_summary(messages, _none), do: messages

  defp estimate_tokens(messages) do
    messages
    |> Enum.map(&String.length(&1.content || ""))
    |> Enum.sum()
    |> div(4)
  end

  # Newest-first walk keeps recent turns up to the keep budget (always
  # at least the current user message); everything older folds.
  defp split_for_memory(completed) do
    {kept_reversed, _spent} =
      completed
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn message, {kept, spent} ->
        cost = div(String.length(message.content || ""), 4)

        if kept == [] or spent + cost <= @memory_keep_tokens do
          {[message | kept], spent + cost}
        else
          {kept, @memory_keep_tokens + 1}
        end
      end)

    kept = kept_reversed
    folded = completed -- kept
    {folded, kept}
  end

  defp update_summary(app, %Conversation{} = conversation, folded) do
    boundary = folded |> Enum.map(&(&1.seq || 0)) |> Enum.max(fn -> 0 end)

    if conversation.summarized_seq && conversation.summarized_seq >= boundary do
      {:ok, conversation.summary}
    else
      fresh = Enum.filter(folded, &((&1.seq || 0) > (conversation.summarized_seq || 0)))

      case summarize(app, conversation.summary, fresh) do
        {:ok, summary} ->
          conversation
          |> Ecto.Changeset.change(summary: summary, summarized_seq: boundary)
          |> Repo.update()

          {:ok, summary}

        :error ->
          :error
      end
    end
  end

  defp update_summary(_app, _missing_conversation, _folded), do: :error

  defp summarize(app, previous_summary, fresh_turns) do
    transcript =
      Enum.map_join(fresh_turns, "\n", fn message ->
        "#{message.role}: #{String.slice(message.content || "", 0, 2_000)}"
      end)

    prompt =
      """
      Maintain a running summary of a conversation. Keep every fact,
      name, decision, and open question; drop pleasantries. Reply with
      the updated summary only, under 300 words.
      """ <>
        ((previous_summary && "\n\nCurrent summary:\n#{previous_summary}") || "") <>
        "\n\nNew turns to fold in:\n#{transcript}"

    # Chatflow apps have no bound model — the workspace default folds.
    if app.provider_plugin_id in [nil, ""] do
      case Flux.Workflows.invoke_default_llm_for_workspace(app.workspace_id, [
             %{role: :user, content: prompt}
           ]) do
        {:ok, content} when is_binary(content) and content != "" -> {:ok, content}
        _error -> :error
      end
    else
      credentials =
        case Providers.fetch_config(app.workspace_id, app.provider_plugin_id) do
          {:ok, config} -> config
          {:error, :not_configured} -> %{}
        end

      request = %Flux.Plugin.ModelProvider.Request{
        model: app.model,
        messages: [%{role: :user, content: prompt}],
        params: %{}
      }

      case runtime().invoke_llm(
             app.provider_plugin_id,
             credentials,
             request,
             fn _chunk -> :ok end
           ) do
        {:ok, %{content: content}} when is_binary(content) and content != "" -> {:ok, content}
        _error -> :error
      end
    end
  end

  @doc """
  Speech-to-text through the app's provider (voice input in chat).
  `opts` may carry `:filename`/`:content_type`. `{:error, :not_supported}`
  when the provider has no transcription endpoint.
  """
  def transcribe_audio(%Scope{} = _scope, %App{} = app, audio, opts \\ %{})
      when is_binary(audio) do
    provider =
      case app.mode do
        # Chatflow apps have no direct provider; use the workspace default.
        :advanced_chat ->
          case Providers.default_model_for_workspace(app.workspace_id) do
            %{"provider_plugin_id" => plugin_id} -> plugin_id
            _none -> nil
          end

        _direct ->
          app.provider_plugin_id
      end

    if provider in [nil, ""] do
      {:error, :not_supported}
    else
      credentials =
        case Providers.fetch_config(app.workspace_id, provider) do
          {:ok, config} -> config
          {:error, :not_configured} -> %{}
        end

      case runtime().invoke_transcription(provider, credentials, audio, opts) do
        {:ok, %{text: text}} -> {:ok, text}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Text-to-speech through the app's provider (read-aloud with real model
  voices). `{:error, :not_supported}` when the provider has no speech
  endpoint — callers fall back to browser voices.
  """
  def synthesize_speech(%Scope{} = _scope, %App{} = app, text) when is_binary(text) do
    provider =
      case app.mode do
        :advanced_chat ->
          case Providers.default_model_for_workspace(app.workspace_id) do
            %{"provider_plugin_id" => plugin_id} -> plugin_id
            _none -> nil
          end

        _direct ->
          app.provider_plugin_id
      end

    if provider in [nil, ""] do
      {:error, :not_supported}
    else
      credentials =
        case Providers.fetch_config(app.workspace_id, provider) do
          {:ok, config} -> config
          {:error, :not_configured} -> %{}
        end

      runtime().invoke_speech(provider, credentials, text, %{})
    end
  end

  @chatflow_bridge_timeout :timer.minutes(5)

  @doc """
  Stateless OpenAI-style completion for a **chatflow** app: runs the
  bound flux's serving version with the last user message as the query
  and the earlier turns as `{{sys.history}}`. Streams answer deltas via
  `emit`; nothing is persisted. Same return contract as
  `stateless_completion/3`.
  """
  def stateless_chatflow_completion(%App{mode: :advanced_chat} = app, messages, emit) do
    scope = site_scope(app)

    workflow =
      app.workflow_id &&
        Repo.get_by(Flux.Workflows.Workflow, [id: app.workflow_id], skip_workspace_guard: true)

    with %Flux.Workflows.Workflow{deleted_at: nil} = workflow <-
           workflow || {:error, :not_published},
         %{graph: graph, version: version} <-
           Flux.Workflows.serving_version(scope, workflow) || {:error, :not_published} do
      {query, prior} =
        case Enum.split_with(Enum.reverse(messages), &(&1.role == :user)) do
          {[last_user | _], _} -> {last_user.content, Enum.reject(messages, &(&1 == last_user))}
          {[], _} -> {"", messages}
        end

      history_text =
        Enum.map_join(prior, "\n", fn message -> "#{message.role}: #{message.content}" end)

      with {:ok, _run} <-
             Flux.Workflows.start_run(scope, workflow, %{"query" => query},
               graph: graph,
               version: version,
               source: :api,
               sys: %{
                 "query" => query,
                 "history" => history_text,
                 "turns" => div(length(prior), 2)
               }
             ) do
        await_chatflow_bridge(emit, "", "flux/#{workflow.name}")
      end
    end
  end

  defp await_chatflow_bridge(emit, answer, model_label) do
    receive do
      {:engine_event, {:node_chunk, %{delta: delta}}} ->
        emit.(%{delta: delta})
        await_chatflow_bridge(emit, answer <> delta, model_label)

      {:engine_event, _other} ->
        await_chatflow_bridge(emit, answer, model_label)

      {:run_finished, run} ->
        case run.status do
          :succeeded ->
            final = (answer != "" && answer) || to_string(run.outputs["answer"] || "")
            if answer == "" and final != "", do: emit.(%{delta: final})

            {:ok,
             %{
               content: final,
               usage: %{
                 input_tokens: run.usage["input_tokens"] || 0,
                 output_tokens: run.usage["output_tokens"] || 0
               }
             }, model_label}

          _failed_or_stopped ->
            {:error, run.error || "the flux run failed"}
        end
    after
      @chatflow_bridge_timeout -> {:error, :timeout}
    end
  end

  @doc """
  Stateless completion over an app's model for the OpenAI-compatible
  endpoint: the caller supplies the whole message history, nothing is
  persisted. The app's system prompt, params, and fallback model all
  apply; provider health records both sides. Returns
  `{:ok, result, model_used}` or `{:error, reason}`.
  """
  def stateless_completion(app, messages, emit, opts \\ [])

  def stateless_completion(%App{} = app, messages, emit, opts) when is_list(messages) do
    messages =
      case {app.system_prompt, messages} do
        {prompt, [%{role: :system} | _rest]} when is_binary(prompt) ->
          messages

        {prompt, _no_system} when is_binary(prompt) and prompt != "" ->
          [%{role: :system, content: prompt} | messages]

        _no_prompt ->
          messages
      end

    request = %Flux.Plugin.ModelProvider.Request{
      model: app.model,
      messages: messages,
      params: atomize_params(app.params),
      # OpenAI-compat function calling: caller-supplied tool definitions
      # pass straight through; any tool_calls come back on the result.
      tools: Keyword.get(opts, :tools, [])
    }

    case invoke_with_credentials(app.workspace_id, app.provider_plugin_id, request, emit) do
      {:ok, result} ->
        {:ok, result, "#{app.provider_plugin_id}/#{app.model}"}

      {:error, reason} ->
        fallback_plugin = app.fallback_provider_plugin_id
        fallback_model = app.fallback_model

        if is_binary(fallback_plugin) and fallback_plugin != "" and
             is_binary(fallback_model) and fallback_model != "" do
          case invoke_with_credentials(
                 app.workspace_id,
                 fallback_plugin,
                 %{request | model: fallback_model},
                 emit
               ) do
            {:ok, result} -> {:ok, result, "#{fallback_plugin}/#{fallback_model}"}
            {:error, _fallback_reason} -> {:error, reason}
          end
        else
          {:error, reason}
        end
    end
  end

  defp invoke_with_credentials(workspace_id, plugin_id, request, emit) do
    credentials =
      case Providers.fetch_config(workspace_id, plugin_id) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    case runtime().invoke_llm(plugin_id, credentials, request, emit) do
      {:ok, result} ->
        Flux.ProviderHealth.record(plugin_id, :ok)
        {:ok, result}

      {:error, reason} ->
        Flux.ProviderHealth.record(plugin_id, :error)
        {:error, reason}
    end
  end

  # Prior turns, oldest first, minus the current user message and the
  # streaming placeholder.
  defp chatflow_history(history) do
    history
    |> Enum.reject(&(&1.status == :streaming))
    |> Enum.reverse()
    |> case do
      [%Message{role: :user} | prior] -> prior
      prior -> prior
    end
    |> Enum.reverse()
    |> Enum.filter(&(&1.status == :completed or &1.role == :user))
    |> Enum.map_join("\n", fn message -> "#{message.role}: #{message.content}" end)
  end

  @chatflow_timeout :timer.minutes(5)

  defp bridge_run(assistant_message, conversation, variables, citations \\ [], files \\ []) do
    receive do
      {:engine_event, {:node_chunk, %{delta: delta}}} ->
        Flux.StreamBuffers.append(assistant_message.id, delta)
        Phoenix.PubSub.broadcast(Flux.PubSub, topic(assistant_message.id), {:chunk, delta})
        bridge_run(assistant_message, conversation, variables, citations, files)

      {:engine_event, {:conversation_var_set, %{name: name, value: value}}} ->
        bridge_run(
          assistant_message,
          conversation,
          Map.put(variables, name, value),
          citations,
          files
        )

      # Knowledge nodes expose their sources in outputs["citations"];
      # collect them so the answer can show where it came from.
      {:engine_event, {:node_finished, %{outputs: %{"citations" => node_citations}}}}
      when is_list(node_citations) ->
        bridge_run(assistant_message, conversation, variables, citations ++ node_citations, files)

      # Document nodes produce downloadable files; the reply carries them.
      {:engine_event,
       {:node_finished, %{outputs: %{"file_id" => _id, "url" => url, "name" => name} = outputs}}} ->
        file = %{"name" => name, "url" => url, "size" => outputs["size"]}
        bridge_run(assistant_message, conversation, variables, citations, files ++ [file])

      {:engine_event, _other} ->
        bridge_run(assistant_message, conversation, variables, citations, files)

      {:run_finished, run} ->
        if variables != %{} do
          conversation
          |> Ecto.Changeset.change(variables: Map.merge(conversation.variables || %{}, variables))
          |> Repo.update()
        end

        case run.status do
          :succeeded ->
            answer =
              case Flux.StreamBuffers.get(assistant_message.id) do
                "" -> to_string(run.outputs["answer"] || "")
                streamed -> streamed
              end

            usage = (files == [] && %{}) || %{"files" => Enum.take(files, 10)}
            finalize(assistant_message, :completed, answer, usage, citations)

          _failed_or_stopped ->
            fail_generation(assistant_message, run.error || "The flux run failed.")
        end
    after
      @chatflow_timeout ->
        fail_generation(assistant_message, "The flux run timed out.")
    end
  end

  defp fail_generation(assistant_message, error) do
    Flux.StreamBuffers.delete(assistant_message.id)

    message =
      assistant_message
      |> Ecto.Changeset.change(status: :error, error: error)
      |> Repo.update!()

    Phoenix.PubSub.broadcast(Flux.PubSub, topic(assistant_message.id), {:error, message})
    {:error, error}
  end

  defp finalize(message, status, content, usage, citations \\ []) do
    Flux.StreamBuffers.delete(message.id)

    # Redact-mode guardrails mask model output before it's stored;
    # other modes flag-and-notify without touching the reply.
    content =
      (status == :completed && Flux.Guardrails.sanitize_output(message.workspace_id, content)) ||
        content

    message =
      message
      |> Ecto.Changeset.change(status: status, content: content, usage: usage)
      |> Ecto.Changeset.change(citations: dedupe_citations(citations))
      |> Repo.update!()

    Phoenix.PubSub.broadcast(Flux.PubSub, topic(message.id), {:done, message})
    {:ok, message}
  end

  defp dedupe_citations(citations) do
    citations
    |> Enum.uniq_by(&{&1["document"], &1["content"]})
    |> Enum.take(10)
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
      |> Enum.map(fn message ->
        base = %{role: message.role, content: message.content}

        case load_images(message.files || []) do
          [] -> base
          images -> Map.put(base, :images, images)
        end
      end)

    system ++ turns
  end

  # Attached image files become base64 payloads for vision-capable
  # providers (the SDK's `images` message key). Unreadable files and
  # non-images are skipped rather than failing the whole turn.
  defp load_images(files) do
    for %{"id" => id, "content_type" => "image/" <> _subtype = content_type} <- files,
        file = Repo.get(Flux.Chat.UploadedFile, id, skip_workspace_guard: true),
        file != nil,
        {:ok, binary} <- [Flux.Storage.get(file.key)] do
      %{data: Base.encode64(binary), media_type: content_type}
    end
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
