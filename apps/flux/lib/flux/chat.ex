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

  @doc """
  Sets (or with a blank passcode clears) the passcode gate on the app's
  public site. Visitors enter it once per browser session.
  """
  def set_site_passcode(%Scope{} = scope, %App{} = app, passcode) do
    with :ok <- RBAC.authorize(scope, :app_create_and_management),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      hash =
        case String.trim(to_string(passcode)) do
          "" -> nil
          passcode -> hash_passcode(passcode)
        end

      with {:ok, updated} <-
             app |> Ecto.Changeset.change(site_passcode_hash: hash) |> Repo.update() do
        Flux.Audit.record(scope, "app.site_passcode",
          resource: app,
          metadata: %{"set" => hash != nil}
        )

        {:ok, updated}
      end
    end
  end

  @doc "Whether the visitor-typed passcode opens this app's site."
  def site_passcode_ok?(%App{site_passcode_hash: hash}, passcode) when is_binary(hash) do
    :crypto.hash_equals(hash, hash_passcode(String.trim(to_string(passcode))))
  end

  def site_passcode_ok?(_app, _passcode), do: false

  defp hash_passcode(passcode) do
    :sha256 |> :crypto.hash(passcode) |> Base.encode16(case: :lower)
  end

  @doc "Resolves a public site token to its app; the token is the authorization."
  def get_app_by_site_token("site_" <> _rest = token) do
    case Repo.get_by(App, [site_token: token], skip_workspace_guard: true) do
      %App{site_enabled: true, deleted_at: nil} = app -> {:ok, app}
      # Disabled (not trashed) shows a friendly maintenance page instead
      # of hard-404ing visitors mid-conversation.
      %App{site_enabled: false, deleted_at: nil} = app -> {:error, {:maintenance, app}}
      _trashed_or_missing -> {:error, :not_found}
    end
  end

  def get_app_by_site_token(_other), do: {:error, :not_found}

  @doc """
  The CSP `frame-ancestors` sources locking down who may iframe a
  published app site, or nil for the embed-anywhere default (also what
  flux sites and unknown tokens get).
  """
  def embed_frame_ancestors("site_" <> _rest = token) do
    case Repo.get_by(App, [site_token: token], skip_workspace_guard: true) do
      %App{embed_origins: origins} when is_binary(origins) ->
        case String.split(origins, ~r/\s+/, trim: true) do
          [] -> nil
          list -> list
        end

      _default ->
        nil
    end
  end

  def embed_frame_ancestors(_other), do: nil

  @business_days ~w(mon tue wed thu fri sat sun)

  @doc """
  Whether the app's public site is inside its configured business hours
  (UTC). No or empty config means always open; overnight windows
  (open > close) wrap past midnight.
  """
  def within_business_hours?(%App{business_hours: hours}, now \\ DateTime.utc_now()) do
    case hours do
      %{"days" => [_ | _] = days, "open" => open, "close" => close}
      when is_integer(open) and is_integer(close) ->
        day = Enum.at(@business_days, Date.day_of_week(now) - 1)

        hour_ok =
          if open <= close,
            do: now.hour >= open and now.hour < close,
            else: now.hour >= open or now.hour < close

        day in days and hour_ok

      _always_open ->
        true
    end
  end

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
    conversation =
      Repo.insert!(%Conversation{
        workspace_id: Scope.workspace_id(scope),
        app_id: app.id,
        title: Map.get(attrs, :title),
        end_user_ref: Map.get(attrs, :end_user_ref)
      })

    notify_monitor(app.id, conversation.id)

    Flux.Webhooks.dispatch(conversation.workspace_id, "conversation.started", %{
      "conversation_id" => conversation.id,
      "app_id" => app.id,
      "end_user_ref" => conversation.end_user_ref
    })

    conversation
  end

  def get_conversation(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Conversation, id: ^id), scope)) || {:error, :not_found}
  end

  @doc "One message in the scope's workspace, or {:error, :not_found}."
  def get_message(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Message, id: ^id), scope)) || {:error, :not_found}
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
          |> Ecto.Changeset.change(
            handoff_requested_at: DateTime.utc_now(:second),
            # Re-arm the overdue-handoff SLA alert for this new request.
            handoff_alerted_at: nil
          )
          |> Repo.update()

        Flux.Notifications.notify(
          app.workspace_id,
          "handoff",
          "A visitor asked for a human in #{app.name}.",
          "/console/apps/#{app.id}/monitor"
        )

        Flux.Webhooks.dispatch(app.workspace_id, "handoff.requested", %{
          "conversation_id" => conversation.id,
          "app_id" => app.id
        })

        flagged = maybe_auto_assign(app, flagged)
        notify_monitor(app.id, conversation.id)

        {:ok, flagged}

      %Conversation{} = already_flagged ->
        {:ok, already_flagged}

      error ->
        error
    end
  end

  # Round-robin new handoffs across available members when the
  # workspace opted in — nobody has to claim, everybody gets a turn.
  defp maybe_auto_assign(app, conversation) do
    with %{custom_config: %{"handoff_auto_assign" => true}} <-
           Repo.get(Flux.Accounts.Workspace, app.workspace_id),
         [_ | _] = member_ids <- Flux.Accounts.available_member_ids(app.workspace_id) do
      turn = rem(System.unique_integer([:positive, :monotonic]), length(member_ids))

      {:ok, assigned} =
        conversation
        |> Ecto.Changeset.change(assigned_account_id: Enum.at(member_ids, turn))
        |> Repo.update()

      assigned
    else
      _off_or_nobody -> conversation
    end
  end

  @doc """
  A teammate answers from the console: inserts a completed assistant
  message (marked human), clears the handoff flag, and broadcasts on the
  conversation topic so an open site chat sees it live.
  """
  def human_reply(scope, conversation_id, content, opts \\ [])

  def human_reply(%Scope{} = scope, conversation_id, content, opts)
      when is_binary(content) and content != "" do
    with %Conversation{} = conversation <- get_conversation(scope, conversation_id) do
      maybe_mail_away_visitor(conversation, content)

      message =
        Repo.insert!(%Message{
          workspace_id: conversation.workspace_id,
          conversation_id: conversation.id,
          role: :assistant,
          content: content,
          status: :completed,
          files: Keyword.get(opts, :files, []),
          usage: %{"human" => true, "author" => (scope.account && scope.account.email) || ""}
        })

      # First human reply after a handoff request: record the wait once —
      # the support-latency metric the queue can't show after the flag
      # clears.
      first_reply_seconds =
        if conversation.handoff_requested_at && conversation.handoff_first_reply_seconds == nil do
          DateTime.diff(DateTime.utc_now(:second), conversation.handoff_requested_at)
        else
          conversation.handoff_first_reply_seconds
        end

      {:ok, conversation} =
        conversation
        |> Ecto.Changeset.change(
          handoff_requested_at: nil,
          handoff_first_reply_seconds: first_reply_seconds
        )
        |> Repo.update()

      Phoenix.PubSub.broadcast(
        Flux.PubSub,
        conversation_topic(conversation.id),
        {:human_reply, message}
      )

      notify_monitor(conversation.app_id, conversation.id)

      {:ok, message}
    end
  end

  @doc "Marks a conversation resolved (a fresh visitor message reopens it)."
  def resolve_conversation(%Scope{} = scope, conversation_id),
    do: set_resolved(scope, conversation_id, DateTime.utc_now(:second))

  @doc "Reopens a resolved conversation."
  def reopen_conversation(%Scope{} = scope, conversation_id),
    do: set_resolved(scope, conversation_id, nil)

  defp set_resolved(scope, conversation_id, at) do
    with :ok <- RBAC.authorize(scope, :app_monitor),
         %Conversation{} = conversation <-
           Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) ||
             {:error, :not_found},
         {:ok, updated} <-
           conversation |> Ecto.Changeset.change(resolved_at: at) |> Repo.update() do
      notify_monitor(updated.app_id, updated.id)
      {:ok, updated}
    end
  end

  @doc "Open/resolved tallies for the monitor header (last 30 days)."
  def resolution_counts(%Scope{} = scope, app_id) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -30, :day)

    counts =
      Conversation
      |> Repo.scoped(scope)
      |> where([c], c.app_id == ^app_id and is_nil(c.deleted_at) and c.inserted_at >= ^cutoff)
      |> group_by([c], is_nil(c.resolved_at))
      |> select([c], {is_nil(c.resolved_at), count(c.id)})
      |> Repo.all()
      |> Map.new()

    %{open: Map.get(counts, true, 0), resolved: Map.get(counts, false, 0)}
  end

  @doc """
  Every-minute tick: workspaces that configured `handoff_alert_minutes`
  get a notification when a handoff sits unanswered that long — once
  per request (a fresh request re-arms it).
  """
  def check_handoff_sla(now \\ DateTime.utc_now(:second)) do
    workspaces =
      from(w in Flux.Accounts.Workspace,
        where: fragment("(? ->> 'handoff_alert_minutes') is not null", w.custom_config),
        select: {w.id, fragment("(? ->> 'handoff_alert_minutes')::int", w.custom_config)}
      )
      |> Repo.all()

    for {workspace_id, minutes} <- workspaces, is_integer(minutes) and minutes > 0 do
      cutoff = DateTime.add(now, -minutes, :minute)

      overdue =
        from(c in Conversation,
          join: a in App,
          on: a.id == c.app_id,
          where: c.workspace_id == ^workspace_id and is_nil(c.deleted_at),
          where: c.handoff_requested_at <= ^cutoff and is_nil(c.handoff_alerted_at),
          select: {c.id, a.id, a.name}
        )
        |> Repo.all()

      for {conversation_id, app_id, app_name} <- overdue do
        Flux.Notifications.notify(
          workspace_id,
          "handoff",
          "A visitor has been waiting #{minutes}+ minutes without a human reply in #{app_name}.",
          "/console/apps/#{app_id}/monitor"
        )

        from(c in Conversation,
          where: c.id == ^conversation_id and c.workspace_id == ^workspace_id
        )
        |> Repo.update_all(set: [handoff_alerted_at: now])
      end
    end

    :ok
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

  @doc """
  GDPR forget: hard-deletes everything for one visitor — conversations
  (messages cascade), their uploaded files (storage included) — and
  writes an audit entry. Returns `{:ok, conversations_deleted}`.
  """
  def forget_visitor(%Scope{} = scope, %App{} = app, end_user_ref)
      when is_binary(end_user_ref) and end_user_ref != "" do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- app.workspace_id == Scope.workspace_id(scope) || {:error, :not_found} do
      conversation_ids =
        Conversation
        |> Repo.scoped(scope)
        |> where([c], c.app_id == ^app.id and c.end_user_ref == ^end_user_ref)
        |> select([c], c.id)
        |> Repo.all()

      file_ids =
        Message
        |> Repo.scoped(scope)
        |> where([m], m.conversation_id in ^conversation_ids)
        |> select([m], m.files)
        |> Repo.all()
        |> List.flatten()
        |> Enum.map(& &1["id"])
        |> Enum.reject(&is_nil/1)

      for file_id <- file_ids,
          file = Repo.get(Flux.Chat.UploadedFile, file_id, skip_workspace_guard: true),
          file != nil do
        Flux.Storage.delete(file.key)
        Repo.delete(file)
      end

      {deleted, _} =
        Conversation
        |> Repo.scoped(scope)
        |> where([c], c.id in ^conversation_ids)
        |> Repo.delete_all()

      Flux.Audit.record(scope, "visitor.forget",
        resource: app,
        metadata: %{"end_user_ref" => end_user_ref, "conversations" => deleted}
      )

      {:ok, deleted}
    end
  end

  @doc "Conversations currently waiting on a human, oldest wait first."
  def handoff_queue(%Scope{} = scope, app_id) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and not is_nil(c.handoff_requested_at))
    |> where([c], is_nil(c.deleted_at))
    |> order_by([c], asc: c.handoff_requested_at)
    |> preload(:assigned_account)
    |> Repo.all()
  end

  @doc """
  Claims (or with nil, releases) a handoff conversation for a member —
  the queue shows who owns what, so two agents stop answering the same
  visitor.
  """
  def assign_handoff(%Scope{} = scope, conversation_id, account_id) do
    with :ok <- RBAC.authorize(scope, :app_monitor),
         %Conversation{} = conversation <-
           Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) ||
             {:error, :not_found},
         {:ok, updated} <-
           conversation
           |> Ecto.Changeset.change(assigned_account_id: account_id)
           |> Repo.update() do
      {:ok, Repo.preload(updated, :assigned_account, force: true)}
    end
  end

  @doc "Stores the visitor's 1-5 rating (re-rating overwrites). Site-scope callable."
  def rate_conversation(%Scope{} = scope, conversation_id, score, comment \\ nil)
      when score in 1..5 do
    case Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) do
      nil ->
        {:error, :not_found}

      conversation ->
        comment = comment |> to_string() |> String.trim() |> String.slice(0, 1_000)

        with {:ok, updated} <-
               conversation
               |> Ecto.Changeset.change(
                 csat_score: score,
                 csat_comment: (comment != "" && comment) || nil
               )
               |> Repo.update() do
          notify_monitor(updated.app_id, updated.id)
          {:ok, updated}
        end
    end
  end

  @doc "CSAT rollup for the monitor (last 30 days): count and average score."
  def csat_stats(%Scope{} = scope, app_id) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -30, :day)

    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.app_id == ^app_id and not is_nil(c.csat_score))
    |> where([c], is_nil(c.deleted_at) and c.inserted_at >= ^cutoff)
    |> select([c], {count(c.id), avg(c.csat_score)})
    |> Repo.one()
    |> case do
      {0, _average} -> %{count: 0, average: nil}
      {count, average} -> %{count: count, average: Float.round(decimal_to_float(average), 2)}
    end
  end

  defp decimal_to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp decimal_to_float(number) when is_number(number), do: number * 1.0

  ## Public conversation share links (read-only transcript pages)

  @doc "Mints (or keeps) the conversation's public transcript token."
  def enable_conversation_share(%Scope{} = scope, conversation_id) do
    with :ok <- RBAC.authorize(scope, :app_monitor),
         %Conversation{} = conversation <-
           Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) ||
             {:error, :not_found} do
      case conversation.share_token do
        nil ->
          token = "convshare_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
          conversation |> Ecto.Changeset.change(share_token: token) |> Repo.update()

        _already_shared ->
          {:ok, conversation}
      end
    end
  end

  @doc "Revokes the public transcript link."
  def disable_conversation_share(%Scope{} = scope, conversation_id) do
    with :ok <- RBAC.authorize(scope, :app_monitor),
         %Conversation{} = conversation <-
           Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) ||
             {:error, :not_found} do
      conversation |> Ecto.Changeset.change(share_token: nil) |> Repo.update()
    end
  end

  @doc "Resolves a share token to `{conversation, app, messages}` for the public page."
  def get_shared_conversation("convshare_" <> _rest = token) do
    case Repo.get_by(Conversation, [share_token: token], skip_workspace_guard: true) do
      %Conversation{deleted_at: nil} = conversation ->
        app = Repo.get(App, conversation.app_id, skip_workspace_guard: true)
        messages = list_messages(site_scope(app), conversation.id)
        {:ok, conversation, app, messages}

      _revoked_or_missing ->
        {:error, :not_found}
    end
  end

  def get_shared_conversation(_other), do: {:error, :not_found}

  @doc """
  Marks the conversation's human replies seen — called by the visitor's
  open tab, so agents know the answer landed. Site-scope callable.
  """
  def mark_replies_seen(%Scope{} = scope, conversation_id) do
    now = DateTime.utc_now(:second)

    {count, _} =
      Message
      |> Repo.scoped(scope)
      |> where([m], m.conversation_id == ^conversation_id and m.role == :assistant)
      |> where([m], is_nil(m.seen_at) and fragment("? \\? 'human'", m.usage))
      |> Repo.update_all(set: [seen_at: now])

    if count > 0 do
      case Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) do
        %Conversation{} = conversation -> notify_monitor(conversation.app_id, conversation.id)
        _gone -> :ok
      end
    end

    :ok
  end

  ## Internal notes (agent-only comments, never shown to the visitor)

  alias Flux.Chat.ConversationNote

  @doc "Agent-only notes on a conversation, oldest first."
  def list_conversation_notes(%Scope{} = scope, conversation_id) do
    ConversationNote
    |> Repo.scoped(scope)
    |> where([n], n.conversation_id == ^conversation_id)
    |> order_by([n], asc: n.inserted_at, asc: n.id)
    |> Repo.all()
  end

  @doc "Adds an internal note; the author is the scope's account email."
  def add_conversation_note(%Scope{} = scope, conversation_id, body) do
    body = body |> to_string() |> String.trim()

    with :ok <- RBAC.authorize(scope, :app_monitor),
         true <- body != "" || {:error, :blank},
         %Conversation{} = conversation <-
           Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) ||
             {:error, :not_found} do
      {:ok,
       Repo.insert!(%ConversationNote{
         workspace_id: conversation.workspace_id,
         conversation_id: conversation.id,
         author_email: scope.account && scope.account.email,
         body: String.slice(body, 0, 4_000)
       })}
    end
  end

  @doc "Deletes an internal note."
  def delete_conversation_note(%Scope{} = scope, note_id) do
    with :ok <- RBAC.authorize(scope, :app_monitor),
         %ConversationNote{} = note <-
           Repo.one(Repo.scoped(where(ConversationNote, id: ^note_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(note)
    end
  end

  ## Canned replies (saved snippets for the monitor's human agents)

  @doc "The workspace's saved replies as string-keyed title/body maps, newest first."
  def list_canned_replies(%Scope{} = scope) do
    case Repo.get(Flux.Accounts.Workspace, Scope.workspace_id(scope)) do
      %{custom_config: %{"canned_replies" => replies}} when is_list(replies) -> replies
      _none -> []
    end
  end

  @doc "Saves (upserts by title) a canned reply for human agents."
  def save_canned_reply(%Scope{} = scope, title, body) do
    title = title |> to_string() |> String.trim() |> String.slice(0, 80)
    body = body |> to_string() |> String.trim() |> String.slice(0, 4_000)

    with :ok <- RBAC.authorize(scope, :app_monitor),
         true <- (title != "" and body != "") || {:error, :blank} do
      replies =
        [%{"title" => title, "body" => body}] ++
          Enum.reject(list_canned_replies(scope), &(&1["title"] == title))

      put_canned_replies(scope, Enum.take(replies, 50))
    end
  end

  @doc "Deletes a canned reply by title."
  def delete_canned_reply(%Scope{} = scope, title) do
    with :ok <- RBAC.authorize(scope, :app_monitor) do
      put_canned_replies(
        scope,
        Enum.reject(list_canned_replies(scope), &(&1["title"] == title))
      )
    end
  end

  defp put_canned_replies(scope, replies) do
    workspace = Repo.get(Flux.Accounts.Workspace, Scope.workspace_id(scope))

    workspace
    |> Ecto.Changeset.change(
      custom_config: Map.put(workspace.custom_config || %{}, "canned_replies", replies)
    )
    |> Repo.update()
  end

  @doc """
  Stores the pre-chat identity a visitor typed (collect_visitor_info
  apps). Site-scope callable; blank values clear nothing — identity is
  write-once unless retyped.
  """
  def set_visitor_identity(%Scope{} = scope, conversation_id, name, email) do
    case Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) do
      nil ->
        {:error, :not_found}

      conversation ->
        changes =
          %{}
          |> then(fn changes ->
            case String.trim(to_string(name)) do
              "" -> changes
              name -> Map.put(changes, :visitor_name, String.slice(name, 0, 160))
            end
          end)
          |> then(fn changes ->
            trimmed = String.trim(to_string(email))

            if trimmed =~ ~r/^[^@,;\s]+@[^@,;\s]+$/ do
              Map.put(changes, :visitor_email, String.slice(trimmed, 0, 160))
            else
              changes
            end
          end)

        conversation |> Ecto.Changeset.change(changes) |> Repo.update()
    end
  end

  def conversation_topic(conversation_id), do: "conversation:#{conversation_id}"

  def subscribe_conversation(conversation_id),
    do: Phoenix.PubSub.subscribe(Flux.PubSub, conversation_topic(conversation_id))

  @doc "PubSub topic carrying app-wide monitor nudges (new conversations/messages)."
  def monitor_topic(app_id), do: "app_monitor:#{app_id}"

  def subscribe_monitor(app_id),
    do: Phoenix.PubSub.subscribe(Flux.PubSub, monitor_topic(app_id))

  # Something changed in this conversation — open monitor pages refresh.
  defp notify_monitor(app_id, conversation_id) do
    Phoenix.PubSub.broadcast(
      Flux.PubSub,
      monitor_topic(app_id),
      {:monitor_update, conversation_id}
    )
  end

  @doc """
  Broadcasts a transient typing signal on the conversation topic. The
  site shows `:agent` signals, the monitor shows `:visitor` ones — each
  side ignores its own.
  """
  def broadcast_typing(conversation_id, who) when who in [:visitor, :agent] do
    Phoenix.PubSub.broadcast(
      Flux.PubSub,
      conversation_topic(conversation_id),
      {:typing, conversation_id, who}
    )
  end

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

  @doc "Workspace-wide title search for the command palette's deep lane."
  def search_conversation_titles(%Scope{} = scope, q, limit \\ 8) do
    pattern = "%" <> String.replace(q, ~r/[\\%_]/, fn c -> "\\" <> c end) <> "%"

    Conversation
    |> Repo.scoped(scope)
    |> where([c], is_nil(c.deleted_at) and ilike(c.title, ^pattern))
    |> order_by([c], desc: c.inserted_at)
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
    |> preload(:assigned_account)
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

  @doc "Hard-deletes a trashed conversation now instead of waiting 30 days."
  def purge_conversation(%Scope{} = scope, conversation_id) do
    Conversation
    |> Repo.scoped(scope)
    |> where([c], c.id == ^conversation_id and not is_nil(c.deleted_at))
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      conversation -> Repo.delete(conversation)
    end
  end

  def restore_conversation(%Scope{} = scope, conversation_id) do
    case Repo.one(Repo.scoped(where(Conversation, id: ^conversation_id), scope)) do
      nil ->
        {:error, :not_found}

      conversation ->
        conversation |> Ecto.Changeset.change(deleted_at: nil) |> Repo.update()
    end
  end

  @doc """
  Records end-user feedback (like/dislike/nil to clear) on a message.
  `opts[:comment]` attaches the "what was wrong" text; clearing the
  rating clears the comment with it.
  """
  def set_feedback(%Scope{} = scope, message_id, rating, opts \\ [])
      when rating in [:like, :dislike, nil] do
    case Repo.one(Repo.scoped(where(Message, id: ^message_id), scope)) do
      nil ->
        {:error, :not_found}

      message ->
        comment =
          case {rating, Keyword.get(opts, :comment)} do
            {nil, _cleared} -> nil
            {_rating, text} when is_binary(text) -> presence_slice(text, 1_000)
            {_rating, _unchanged} -> message.feedback_comment
          end

        with {:ok, updated} <-
               message
               |> Ecto.Changeset.change(feedback: rating, feedback_comment: comment)
               |> Repo.update() do
          if rating != nil do
            Flux.Webhooks.dispatch(updated.workspace_id, "feedback.created", %{
              "message_id" => updated.id,
              "conversation_id" => updated.conversation_id,
              "feedback" => to_string(rating),
              "comment" => updated.feedback_comment
            })
          end

          {:ok, updated}
        end
    end
  end

  defp presence_slice(text, max) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max)
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

    # A fresh message reopens a resolved thread; either way the open
    # monitor pages get a nudge.
    if conversation.resolved_at != nil do
      from(c in Conversation,
        where: c.id == ^conversation.id and c.workspace_id == ^workspace_id
      )
      |> Repo.update_all(set: [resolved_at: nil])
    end

    notify_monitor(app.id, conversation.id)

    # Untitled conversations take their first question as the title
    # (manual renames are never overwritten).
    first_exchange? = conversation.title in [nil, ""]

    if first_exchange? do
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

        # After the first reply lands, upgrade the truncated-question
        # title to a model-written one (best effort, never blocking the
        # reply itself).
        if first_exchange?, do: auto_title(workspace_id, conversation.id, content)
      end)

    {:ok, user_message, assistant_message}
  end

  # Replaces the derived first-question title with a short LLM-written
  # one — but only while the title still IS the derived one, so a manual
  # rename in the meantime wins. No model (or a failed call) keeps the
  # derived title; tests inject `config :flux, :title_generator`.
  defp auto_title(workspace_id, conversation_id, first_message) do
    generator =
      Application.get_env(:flux, :title_generator) ||
        fn content ->
          prompt = """
          Write a short title (3 to 6 words, no quotes, no trailing
          punctuation) for a conversation that starts with this message:

          #{String.slice(content, 0, 2_000)}
          """

          case Flux.Workflows.invoke_default_llm_for_workspace(workspace_id, [
                 %{role: :user, content: prompt}
               ]) do
            {:ok, title} when is_binary(title) -> title
            _error_or_no_model -> nil
          end
        end

    with title when is_binary(title) <- generator.(first_message),
         title = title |> String.trim() |> String.trim("\"") |> String.slice(0, 80),
         false <- title == "" do
      derived = derive_title(first_message)

      from(c in Conversation,
        where:
          c.id == ^conversation_id and c.workspace_id == ^workspace_id and
            c.title == ^derived
      )
      |> Repo.update_all(set: [title: title])
    end

    :ok
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

  @doc """
  Rewrites the conversation's last user message and regenerates the
  reply from it. Everything after the edited message is discarded, and
  the new content passes the same guardrails as a fresh send. Returns
  `{:ok, user_message, assistant_message}`.
  """
  def edit_message(
        %Scope{} = scope,
        %App{} = app,
        %Conversation{} = conversation,
        message_id,
        content
      )
      when is_binary(content) and content != "" do
    with :ok <- if(quota_exceeded?(app), do: {:error, :quota_exceeded}, else: :ok),
         {:ok, content} <-
           Flux.Guardrails.sanitize_input(app.workspace_id, content, "chat (#{app.name})"),
         {_earlier, [%Message{role: :user} = target | later]} <-
           scope
           |> list_messages(conversation.id)
           |> Enum.split_while(&(&1.id != message_id)) do
      cond do
        Enum.any?(later, &(&1.role == :user)) -> {:error, :not_last}
        Enum.any?(later, &(&1.status == :streaming)) -> {:error, :busy}
        true -> apply_message_edit(scope, app, conversation, target, later, content)
      end
    else
      {:error, reason} -> {:error, reason}
      _not_found_or_not_user -> {:error, :not_found}
    end
  end

  defp apply_message_edit(scope, app, conversation, target, later, content) do
    workspace_id = Scope.workspace_id(scope)
    target = target |> Ecto.Changeset.change(content: content) |> Repo.update!()

    later_ids = Enum.map(later, & &1.id)

    if later_ids != [] do
      from(m in Message, where: m.id in ^later_ids and m.workspace_id == ^workspace_id)
      |> Repo.delete_all()
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

    {:ok, target, assistant_message}
  end

  # A human replied but the visitor's tab is closed: if they left an
  # email, send a heads-up with the site link. Presence is resolved at
  # runtime (the tracker lives in the web app); no tracker means we
  # can't know they're away, so we stay quiet rather than spam.
  defp maybe_mail_away_visitor(%Conversation{visitor_email: email} = conversation, content)
       when is_binary(email) do
    presence = Application.get_env(:flux, :site_presence)

    away? =
      presence != nil and Code.ensure_loaded?(presence) and
        function_exported?(presence, :visitor_present?, 1) and
        not presence.visitor_present?(conversation.id)

    if away? do
      app = Repo.get(App, conversation.app_id, skip_workspace_guard: true)

      Flux.Accounts.AccountNotifier.deliver_away_reply(
        email,
        (app && app.name) || "the team",
        String.slice(content, 0, 500),
        app && app.site_token,
        conversation.workspace_id
      )
    end

    :ok
  end

  defp maybe_mail_away_visitor(_conversation, _content), do: :ok

  @doc """
  Emails the transcript to the address the visitor shared on this
  conversation; `{:error, :no_email}` when they never left one.
  """
  def email_transcript(%Scope{} = scope, %App{} = app, conversation_id) do
    with %Conversation{app_id: app_id} = conversation <-
           get_conversation(scope, conversation_id) || {:error, :not_found},
         true <- app_id == app.id || {:error, :not_found},
         email when is_binary(email) <- conversation.visitor_email || {:error, :no_email} do
      transcript = render_transcript(scope, app, conversation)

      case Flux.Accounts.AccountNotifier.deliver_transcript(
             email,
             app.name,
             transcript,
             app.workspace_id
           ) do
        {:ok, _email} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :not_found}
    end
  end

  defp render_transcript(scope, app, conversation) do
    scope
    |> list_messages(conversation.id)
    |> Enum.reject(&(&1.content in [nil, ""]))
    |> Enum.map_join("\n\n", fn message ->
      speaker =
        case message.role do
          :user -> conversation.visitor_name || "You"
          :assistant -> app.name
          other -> other |> to_string() |> String.capitalize()
        end

      "#{speaker}:\n#{message.content}"
    end)
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
           end_user_ref: Map.get(upload, :end_user_ref),
           # Agent attachments get a /files/:token URL so the visitor
           # can download what the human sent back.
           download_token:
             (Map.get(upload, :downloadable) &&
                "file_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)) ||
               nil,
           extracted_text: extract_document_text(filename, Map.get(upload, :content_type), binary)
         })}
      end
    end
  end

  defp check_size(bytes) when bytes <= @max_upload_bytes, do: :ok
  defp check_size(_bytes), do: {:error, :too_large}

  # Document uploads get their text pulled out once, at store time, so
  # every later turn can hand it to the model without re-extraction.
  # Images and audio pass through untouched (vision/transcription own
  # those); extraction failures degrade to a plain attachment.
  @document_text_limit 24_000
  defp extract_document_text(_name, "image/" <> _subtype, _binary), do: nil
  defp extract_document_text(_name, "audio/" <> _subtype, _binary), do: nil
  defp extract_document_text(_name, "video/" <> _subtype, _binary), do: nil

  defp extract_document_text(name, content_type, binary) do
    case Flux.Documents.extract_binary(name, content_type, binary) do
      {:ok, text} when is_binary(text) and text != "" ->
        String.slice(text, 0, @document_text_limit)

      _not_extractable ->
        nil
    end
  end

  @doc "Fetches an uploaded file in the scope's workspace, or nil."
  def get_uploaded_file(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(Flux.Chat.UploadedFile, id: ^id), scope))
  end

  @doc "Whether the app's daily token budget (input+output, UTC day) is spent."
  def quota_exceeded?(%App{daily_token_limit: nil, monthly_cost_budget: nil}), do: false

  def quota_exceeded?(%App{} = app) do
    daily_tokens_exceeded?(app) or monthly_budget_exceeded?(app)
  end

  defp daily_tokens_exceeded?(%App{daily_token_limit: nil}), do: false

  defp daily_tokens_exceeded?(%App{daily_token_limit: limit} = app) do
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

  # Estimated month-to-date spend vs the app's monthly USD budget: the
  # same per-model Pricing.estimate the console shows, summed from this
  # month's assistant messages.
  defp monthly_budget_exceeded?(%App{monthly_cost_budget: nil}), do: false

  defp monthly_budget_exceeded?(%App{monthly_cost_budget: budget} = app) do
    month_cost_estimate(app) >= budget
  end

  # Pricing.estimate answers {:ok, cost} | :unknown — normalize to a
  # number so cost rollups can sum without pattern-matching everywhere.
  defp price_estimate(model, input, output) do
    case Flux.Pricing.estimate(model, input, output) do
      {:ok, cost} -> cost
      _unknown -> 0.0
    end
  end

  @doc "Month-to-date estimated USD spend for one app's chat replies."
  def month_cost_estimate(%App{} = app) do
    start_of_month =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00])

    Message
    |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
    |> where([m, c], c.app_id == ^app.id and m.workspace_id == ^app.workspace_id)
    |> where([m], m.role == :assistant and m.inserted_at >= ^start_of_month)
    |> group_by([m], fragment("? ->> 'model_used'", m.usage))
    |> select([m], %{
      model: fragment("? ->> 'model_used'", m.usage),
      input: sum(fragment("coalesce((? ->> 'input_tokens')::bigint, 0)", m.usage)),
      output: sum(fragment("coalesce((? ->> 'output_tokens')::bigint, 0)", m.usage))
    })
    |> Repo.all()
    |> Enum.reduce(0.0, fn row, acc ->
      case row.model do
        model when is_binary(model) ->
          acc + price_estimate(model, decimal_to_int(row.input), decimal_to_int(row.output))

        _unknown ->
          acc
      end
    end)
  end

  @doc """
  Hourly tick: apps at ≥80% (then ≥100%) of their monthly cost budget
  land a `budget_warning` notification, once per level per month — the
  hard cutoff shouldn't be the first anyone hears of it. Subscribed
  members get it by email like any other notification kind.
  """
  def check_app_budget_alerts(now \\ DateTime.utc_now(:second)) do
    if now.minute == 5 do
      month = Calendar.strftime(now, "%Y-%m")

      apps =
        App
        |> where([a], not is_nil(a.monthly_cost_budget) and is_nil(a.deleted_at))
        |> Repo.all(skip_workspace_guard: true)

      for app <- apps do
        spent = month_cost_estimate(app)
        level = budget_level(spent, app.monthly_cost_budget)

        if level > ((app.budget_alerts || %{})[month] || 0) do
          percent = trunc(spent / app.monthly_cost_budget * 100)

          Flux.Notifications.notify(
            app.workspace_id,
            "budget_warning",
            "App #{app.name} is at #{percent}% of its $#{app.monthly_cost_budget} monthly " <>
              "budget (~$#{Float.round(spent, 2)} estimated).",
            "/console/apps/#{app.id}/chat"
          )

          # Old month keys age out with the replace — one key at a time.
          app |> Ecto.Changeset.change(budget_alerts: %{month => level}) |> Repo.update()
        end
      end
    end

    :ok
  end

  defp budget_level(spent, budget) when spent >= budget, do: 100
  defp budget_level(spent, budget) when spent >= budget * 0.8, do: 80
  defp budget_level(_spent, _budget), do: 0

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

  @doc """
  Edits an annotation in place. A changed question re-embeds (stale
  vectors would silently mis-match); `enabled` toggles it out of
  matching without losing the pair.
  """
  def update_annotation(%Scope{} = scope, annotation_id, attrs) when is_map(attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Annotation{} = annotation <-
           Repo.one(Repo.scoped(where(Annotation, id: ^annotation_id), scope)) ||
             {:error, :not_found} do
      question = String.trim(to_string(attrs[:question] || annotation.question))
      answer = String.trim(to_string(attrs[:answer] || annotation.answer))

      with true <- (question != "" and answer != "") || {:error, :empty} do
        changes = %{
          question: question,
          answer: answer,
          enabled: Map.get(attrs, :enabled, annotation.enabled)
        }

        changes =
          if question != annotation.question do
            Map.merge(changes, annotation_embedding(scope, annotation.workspace_id, question))
          else
            changes
          end

        with {:ok, updated} <- annotation |> Ecto.Changeset.change(changes) |> Repo.update() do
          Flux.Audit.record(scope, "annotation.update",
            resource_type: "annotation",
            resource_id: updated.id,
            metadata: %{"app_id" => updated.app_id}
          )

          {:ok, updated}
        end
      end
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

  @doc "Flips a message's pin. Pinned messages surface in the console strip."
  def toggle_pin_message(%Scope{} = scope, message_id) do
    case Repo.one(Repo.scoped(where(Message, id: ^message_id), scope)) do
      nil ->
        {:error, :not_found}

      message ->
        message |> Ecto.Changeset.change(pinned: not message.pinned) |> Repo.update()
    end
  end

  @doc "The conversation's pinned messages, oldest first."
  def pinned_messages(%Scope{} = scope, conversation_id) do
    Message
    |> Repo.scoped(scope)
    |> where([m], m.conversation_id == ^conversation_id and m.pinned)
    |> order_by([m], asc: m.seq)
    |> Repo.all()
  end

  @doc """
  Every completed message of every live (non-trashed) conversation of the
  app, flattened for the monitor's bulk CSV export — newest conversation
  first, messages in order within it. Capped at 10k rows.
  """
  def conversations_csv_rows(%Scope{} = scope, app_id) do
    Message
    |> Repo.scoped(scope)
    |> join(:inner, [m], c in Conversation, on: m.conversation_id == c.id)
    |> where([m, c], c.app_id == ^app_id and is_nil(c.deleted_at))
    |> where([m], m.status in [:completed, :stopped])
    |> order_by([m, c], desc: c.inserted_at, asc: m.seq)
    |> limit(10_000)
    |> select([m, c], %{
      conversation_id: c.id,
      title: c.title,
      end_user_ref: c.end_user_ref,
      role: m.role,
      content: m.content,
      feedback: m.feedback,
      inserted_at: m.inserted_at
    })
    |> Repo.all()
  end

  ## App snapshots

  @snapshot_fields ~w(provider_plugin_id model fallback_provider_plugin_id fallback_model
                      fallbacks ab_provider_plugin_id ab_model ab_split system_prompt prompt_b
                      prompt_split prompt_template input_form params opening_statement
                      suggested_questions daily_token_limit rate_limit_per_minute
                      annotation_threshold suggest_followups collect_visitor_info icon)

  @doc "Saves a named copy of the app's settings (capped at twenty)."
  def snapshot_app(%Scope{} = scope, %App{} = app, name) do
    name = String.trim(to_string(name))

    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- name != "" || {:error, :empty},
         true <- count_snapshots(scope, app.id) < 20 || {:error, :snapshot_limit} do
      config =
        for field <- @snapshot_fields, into: %{} do
          {field, Map.get(app, String.to_existing_atom(field))}
        end

      snapshot =
        Repo.insert!(%Flux.Chat.AppSnapshot{
          workspace_id: app.workspace_id,
          app_id: app.id,
          name: name,
          config: config
        })

      Flux.Audit.record(scope, "app.snapshot", resource: app, metadata: %{"name" => name})
      {:ok, snapshot}
    end
  end

  def list_app_snapshots(%Scope{} = scope, app_id) do
    Flux.Chat.AppSnapshot
    |> Repo.scoped(scope)
    |> where([snapshot], snapshot.app_id == ^app_id)
    |> order_by([snapshot], desc: snapshot.inserted_at)
    |> Repo.all()
  end

  defp count_snapshots(scope, app_id) do
    Flux.Chat.AppSnapshot
    |> Repo.scoped(scope)
    |> where([snapshot], snapshot.app_id == ^app_id)
    |> Repo.aggregate(:count)
  end

  @doc "Applies a snapshot's settings back onto the app (via the changeset)."
  def restore_app_snapshot(%Scope{} = scope, %App{} = app, snapshot_id) do
    with %Flux.Chat.AppSnapshot{app_id: app_id} = snapshot <-
           Repo.one(Repo.scoped(where(Flux.Chat.AppSnapshot, id: ^snapshot_id), scope)) ||
             {:error, :not_found},
         true <- app_id == app.id || {:error, :not_found},
         {:ok, restored} <- update_app(scope, app, snapshot.config) do
      Flux.Audit.record(scope, "app.snapshot_restore",
        resource: app,
        metadata: %{"name" => snapshot.name}
      )

      {:ok, restored}
    end
  end

  def delete_app_snapshot(%Scope{} = scope, snapshot_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Flux.Chat.AppSnapshot{} = snapshot <-
           Repo.one(Repo.scoped(where(Flux.Chat.AppSnapshot, id: ^snapshot_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(snapshot)
    end
  end

  @doc "Token and estimated-cost totals for one conversation's replies."
  def conversation_usage(%Scope{} = scope, conversation_id) do
    messages =
      Message
      |> Repo.scoped(scope)
      |> where([m], m.conversation_id == ^conversation_id and m.role == :assistant)
      |> select([m], m.usage)
      |> Repo.all()

    Enum.reduce(messages, %{input_tokens: 0, output_tokens: 0, cost: 0.0}, fn usage, acc ->
      input = usage["input_tokens"] || 0
      output = usage["output_tokens"] || 0

      cost =
        case usage["model_used"] do
          model when is_binary(model) ->
            price_estimate(model, input, output)

          _unknown ->
            0.0
        end

      %{
        input_tokens: acc.input_tokens + input,
        output_tokens: acc.output_tokens + output,
        cost: acc.cost + cost
      }
    end)
  end

  @doc """
  Median seconds from handoff request to the first human reply over the
  last 30 days — nil when nothing measurable happened.
  """
  def handoff_sla(%Scope{} = scope, app_id) do
    since = DateTime.add(DateTime.utc_now(:second), -30, :day)

    waits =
      Conversation
      |> Repo.scoped(scope)
      |> where([c], c.app_id == ^app_id and not is_nil(c.handoff_first_reply_seconds))
      |> where([c], c.updated_at >= ^since)
      |> select([c], c.handoff_first_reply_seconds)
      |> Repo.all()
      |> Enum.sort()

    case waits do
      [] -> nil
      waits -> %{median_seconds: Enum.at(waits, div(length(waits), 2)), count: length(waits)}
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
          expires_at: token_expiry(opts[:expires_in_days]),
          rate_limit_per_minute: token_rate_limit(opts[:rate_limit_per_minute])
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
  def token_rate_limit(limit) when is_integer(limit) and limit > 0 and limit <= 10_000,
    do: limit

  def token_rate_limit(_off_or_invalid), do: nil

  @doc """
  Daily tick: API keys expiring within seven days get one
  `api_key_expiring` notification (webhook-routable like any kind) —
  the alternative is a silent 401 cliff on whatever automation still
  uses them.
  """
  def warn_expiring_keys(now \\ DateTime.utc_now(:second)) do
    horizon = DateTime.add(now, 7, :day)

    expiring =
      ApiToken
      |> where([t], not is_nil(t.expires_at) and is_nil(t.expiry_warned_at))
      |> where([t], t.expires_at > ^now and t.expires_at < ^horizon)
      |> Repo.all(skip_workspace_guard: true)

    for token <- expiring do
      days_left = max(div(DateTime.diff(token.expires_at, now, :hour), 24), 0)

      Flux.Notifications.notify(
        token.workspace_id,
        "api_key_expiring",
        "API key #{token.prefix} expires in #{days_left + 1} day#{if days_left == 0, do: "", else: "s"} " <>
          "(#{Calendar.strftime(token.expires_at, "%Y-%m-%d")}). Mint a replacement before it dies.",
        "/console/settings"
      )

      token
      |> Ecto.Changeset.change(expiry_warned_at: now)
      |> Repo.update()
    end

    :ok
  end

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
          expires_at: token_expiry(opts[:expires_in_days]),
          rate_limit_per_minute: token_rate_limit(opts[:rate_limit_per_minute])
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
    |> where([t], is_nil(t.app_id) and is_nil(t.workflow_id) and is_nil(t.dataset_id))
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

  @doc """
  Mints a dataset-scoped `ds-` key: it can only touch its one dataset's
  knowledge endpoints — share a KB without workspace-wide power.
  """
  def create_dataset_token(%Scope{} = scope, dataset_id, opts \\ []) do
    with :ok <- RBAC.authorize(scope, :dataset_edit) do
      raw = "ds-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      token =
        Repo.insert!(%ApiToken{
          workspace_id: Scope.workspace_id(scope),
          dataset_id: dataset_id,
          token_hash: :crypto.hash(:sha256, raw),
          prefix: String.slice(raw, 0, 11) <> "…",
          expires_at: token_expiry(opts[:expires_in_days])
        })

      Flux.Audit.record(scope, "api_token.create",
        resource_type: "api_token",
        resource_id: token.id,
        metadata: %{"kind" => "dataset", "dataset_id" => dataset_id}
      )

      {:ok, token, raw}
    end
  end

  @doc "Resolves a ds- token to {dataset_id, workspace_id, token}."
  def fetch_dataset_by_token("ds-" <> _rest = raw) do
    hash = :crypto.hash(:sha256, raw)

    case Repo.get_by(ApiToken, [token_hash: hash], skip_workspace_guard: true) do
      %ApiToken{dataset_id: dataset_id} = token when is_binary(dataset_id) ->
        if token_expired?(token) do
          {:error, :token_expired}
        else
          token
          |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
          |> Repo.update()

          {:ok, dataset_id, token.workspace_id, token}
        end

      _other ->
        {:error, :invalid_token}
    end
  end

  def fetch_dataset_by_token(_other), do: {:error, :invalid_token}

  ## Inbound email channel

  @doc "Mints (or rotates) the app's inbound-email webhook token."
  def enable_email_channel(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      token = "emch_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      app |> Ecto.Changeset.change(email_channel_token: token) |> Repo.update()
    end
  end

  def disable_email_channel(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      app |> Ecto.Changeset.change(email_channel_token: nil) |> Repo.update()
    end
  end

  def get_app_by_email_channel_token("emch_" <> _rest = token) do
    case Repo.get_by(App, [email_channel_token: token], skip_workspace_guard: true) do
      %App{deleted_at: nil} = app -> {:ok, app}
      _missing -> {:error, :not_found}
    end
  end

  def get_app_by_email_channel_token(_other), do: {:error, :not_found}

  @doc """
  An inbound email becomes a chat turn: the sender address keys the
  conversation (one thread per correspondent), the body is the message,
  and once the reply finishes it is mailed back. Returns fast — the
  await-and-mail loop runs in a supervised task so mail-provider
  webhooks never time out.
  """
  def email_inbound(%App{} = app, from, subject, body)
      when is_binary(from) and is_binary(body) and body != "" do
    scope = site_scope(app)
    ref = "email:" <> String.downcase(String.trim(from))

    conversation =
      case latest_conversation(scope, app.id, ref) do
        nil ->
          created = create_conversation(scope, app, %{end_user_ref: ref})
          {:ok, with_identity} = set_visitor_identity(scope, created.id, nil, String.trim(from))
          with_identity

        existing ->
          existing
      end

    content =
      case String.trim(to_string(subject || "")) do
        "" -> body
        trimmed -> "Subject: " <> trimmed <> "\n\n" <> body
      end

    with {:ok, _user, assistant} <- send_message(scope, app, conversation, content) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
          await_and_mail_reply(assistant.id, from, app.name, app.workspace_id)
        end)

      {:ok, conversation.id}
    end
  end

  # send_message subscribed the *caller*; this task polls the row
  # instead so it works from any process.
  defp await_and_mail_reply(message_id, to, app_name, workspace_id) do
    Enum.reduce_while(1..150, nil, fn _try, _acc ->
      case Repo.get(Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} ->
          Process.sleep(1_000)
          {:cont, nil}

        %{status: :completed, content: content} when is_binary(content) and content != "" ->
          Flux.Accounts.AccountNotifier.deliver_channel_reply(to, app_name, content, workspace_id)
          {:halt, :ok}

        _failed_or_gone ->
          {:halt, :error}
      end
    end)
  end

  ## Slack channel (inbound events webhook + bot-token replies)

  @doc """
  Enables the Slack channel: mints the events-webhook token and stores
  the bot token DEK-encrypted (replies post with it).
  """
  def enable_slack_channel(%Scope{} = scope, %App{} = app, bot_token) do
    bot_token = String.trim(to_string(bot_token))

    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- bot_token != "" || {:error, :bot_token_required},
         {:ok, encrypted} <- Flux.Crypto.encrypt(app.workspace_id, bot_token) do
      token = "slch_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      app
      |> Ecto.Changeset.change(slack_channel_token: token, slack_bot_token: encrypted)
      |> Repo.update()
    end
  end

  def disable_slack_channel(%Scope{} = scope, %App{} = app) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      app
      |> Ecto.Changeset.change(slack_channel_token: nil, slack_bot_token: nil)
      |> Repo.update()
    end
  end

  def get_app_by_slack_channel_token("slch_" <> _rest = token) do
    case Repo.get_by(App, [slack_channel_token: token], skip_workspace_guard: true) do
      %App{deleted_at: nil} = app -> {:ok, app}
      _missing -> {:error, :not_found}
    end
  end

  def get_app_by_slack_channel_token(_other), do: {:error, :not_found}

  @doc """
  One Slack message becomes a chat turn: channel + user key the
  conversation, and the reply posts back (threaded when the message
  carried a thread_ts). Returns fast — the await-and-post loop runs in
  a supervised task so the Events API never retries on timeout.
  """
  def slack_inbound(%App{} = app, channel, user, text, thread_ts \\ nil)
      when is_binary(channel) and is_binary(user) and is_binary(text) and text != "" do
    scope = site_scope(app)
    ref = "slack:#{channel}:#{user}"

    conversation =
      latest_conversation(scope, app.id, ref) ||
        create_conversation(scope, app, %{end_user_ref: ref})

    with {:ok, _user_message, assistant} <- send_message(scope, app, conversation, text) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
          await_and_post_slack_reply(assistant.id, app, channel, thread_ts)
        end)

      {:ok, conversation.id}
    end
  end

  defp await_and_post_slack_reply(message_id, app, channel, thread_ts) do
    Enum.reduce_while(1..150, nil, fn _try, _acc ->
      case Repo.get(Message, message_id, skip_workspace_guard: true) do
        %{status: :streaming} ->
          Process.sleep(1_000)
          {:cont, nil}

        %{status: :completed, content: content} when is_binary(content) and content != "" ->
          post_slack_message(app, channel, thread_ts, content)
          {:halt, :ok}

        _failed_or_gone ->
          {:halt, :error}
      end
    end)
  end

  defp post_slack_message(app, channel, thread_ts, text) do
    client = Application.get_env(:flux, :slack_client, &default_slack_client/2)

    with {:ok, bot_token} <- Flux.Crypto.decrypt(app.workspace_id, app.slack_bot_token) do
      payload =
        %{"channel" => channel, "text" => String.slice(text, 0, 4_000)}
        |> then(&((thread_ts && Map.put(&1, "thread_ts", thread_ts)) || &1))

      client.(bot_token, payload)
    end
  end

  defp default_slack_client(bot_token, payload) do
    case Req.post(
           url: "https://slack.com/api/chat.postMessage",
           json: payload,
           headers: [{"authorization", "Bearer " <> bot_token}],
           max_retries: 1,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true}}} -> :ok
      {:ok, %{body: body}} -> {:error, inspect(body)}
      {:error, reason} -> {:error, reason}
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
    # Prompt A/B rides the same rails with an independent coin flip.
    {app, prompt_variant} = pick_prompt_variant(app, assistant_message.conversation_id)

    request = %Flux.Plugin.ModelProvider.Request{
      model: app.model,
      messages: inject_summary(build_prompt(app, history), summary),
      params:
        Map.merge(
          Flux.Accounts.default_model_params(app.workspace_id),
          atomize_params(app.params)
        )
    }

    emit = fn %{delta: delta} ->
      Flux.StreamBuffers.append(assistant_message.id, delta)
      Phoenix.PubSub.broadcast(Flux.PubSub, topic(assistant_message.id), {:chunk, delta})
    end

    result =
      Providers.invoke_with_failover(app.workspace_id, app.provider_plugin_id, fn credentials ->
        runtime().invoke_llm(app.provider_plugin_id, credentials, request, emit)
      end)

    case result do
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

        usage = (prompt_variant == "b" && Map.put(usage, "prompt_variant", "b")) || usage

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

  # prompt_split% of conversations use prompt_b as the system prompt —
  # hashed with a salt so the model and prompt arms stay independent.
  defp pick_prompt_variant(
         %App{prompt_split: split, prompt_b: prompt_b} = app,
         conversation_id
       )
       when is_integer(split) and split > 0 and is_binary(prompt_b) and prompt_b != "" do
    if rem(:erlang.phash2({conversation_id, :prompt}), 100) < split do
      {%{app | system_prompt: prompt_b}, "b"}
    else
      {app, "a"}
    end
  end

  defp pick_prompt_variant(app, _conversation_id), do: {app, "a"}

  @doc "Per-arm reply/feedback stats for the prompt A/B (mirrors app_ab_stats)."
  def prompt_ab_stats(%Scope{} = scope, app_id, limit \\ 1_000) do
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
        "a" => %{replies: 0, likes: 0, dislikes: 0},
        "b" => %{replies: 0, likes: 0, dislikes: 0}
      },
      fn message, acc ->
        arm = (message.usage["prompt_variant"] == "b" && "b") || "a"

        Map.update!(acc, arm, fn stats ->
          %{
            replies: stats.replies + 1,
            likes: stats.likes + ((message.feedback == :like && 1) || 0),
            dislikes: stats.dislikes + ((message.feedback == :dislike && 1) || 0)
          }
        end)
      end
    )
  end

  # Configured backups get one try each, in order, when the primary
  # errors; the reply's usage records which model actually answered.
  defp generate_fallback(app, request, emit, assistant_message, primary_reason) do
    case try_fallbacks(fallback_chain(app), app, request, emit) do
      {:ok, result, plugin, model} ->
        finalize(assistant_message, :completed, result.content, %{
          "input_tokens" => result.usage.input_tokens,
          "output_tokens" => result.usage.output_tokens,
          "model_used" => "#{plugin}/#{model}",
          "fallback_used" => true
        })

      :exhausted ->
        # The primary's error is the honest one to surface.
        generate_error(assistant_message, primary_reason)
    end
  end

  # The legacy single fallback leads; the ordered `fallbacks` list rides
  # behind it.
  defp fallback_chain(app) do
    legacy =
      if is_binary(app.fallback_provider_plugin_id) and app.fallback_provider_plugin_id != "" and
           is_binary(app.fallback_model) and app.fallback_model != "" do
        [{app.fallback_provider_plugin_id, app.fallback_model}]
      else
        []
      end

    extra =
      for %{"provider_plugin_id" => plugin, "model" => model} <- app.fallbacks || [],
          is_binary(plugin) and plugin != "" and is_binary(model) and model != "" do
        {plugin, model}
      end

    Enum.uniq(legacy ++ extra)
  end

  defp try_fallbacks([], _app, _request, _emit), do: :exhausted

  defp try_fallbacks([{plugin, model} | rest], app, request, emit) do
    credentials =
      case Providers.fetch_config(app.workspace_id, plugin) do
        {:ok, config} -> config
        {:error, :not_configured} -> %{}
      end

    case runtime().invoke_llm(plugin, credentials, %{request | model: model}, emit) do
      {:ok, result} ->
        Flux.ProviderHealth.record(plugin, :ok)
        {:ok, result, plugin, model}

      {:error, _reason} ->
        Flux.ProviderHealth.record(plugin, :error)
        try_fallbacks(rest, app, request, emit)
    end
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
      case {combined_system_prompt(app), messages} do
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
      params:
        Map.merge(
          Flux.Accounts.default_model_params(app.workspace_id),
          atomize_params(app.params)
        ),
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

    # Monitor pages refresh live, and webhook receivers hear about the
    # finished turn (thin payload — fetch details via /v1).
    case Repo.get(Conversation, message.conversation_id, skip_workspace_guard: true) do
      %Conversation{} = conversation -> notify_monitor(conversation.app_id, conversation.id)
      _gone -> :ok
    end

    Flux.Webhooks.dispatch(message.workspace_id, "message.completed", %{
      "message_id" => message.id,
      "conversation_id" => message.conversation_id,
      "status" => to_string(status),
      "usage" => usage
    })

    {:ok, message}
  end

  defp dedupe_citations(citations) do
    citations
    |> Enum.uniq_by(&{&1["document"], &1["content"]})
    |> Enum.take(10)
  end

  defp build_prompt(app, history) do
    system =
      case combined_system_prompt(app) do
        prompt when is_binary(prompt) and prompt != "" -> [%{role: :system, content: prompt}]
        _ -> []
      end

    turns =
      history
      |> Enum.filter(&(&1.status == :completed or &1.role == :user))
      |> Enum.map(fn message ->
        base = %{role: message.role, content: message.content}

        base =
          case load_documents(message.files || []) do
            "" -> base
            documents -> %{base | content: to_string(base.content) <> "\n\n" <> documents}
          end

        case load_images(message.files || []) do
          [] -> base
          images -> Map.put(base, :images, images)
        end
      end)

    system ++ turns
  end

  # Attached documents ride into the model as text blocks appended to
  # the turn (per-doc cap keeps a big PDF from eating the whole window).
  defp load_documents(files) do
    files
    |> Enum.reject(&match?(%{"content_type" => "image/" <> _subtype}, &1))
    |> Enum.flat_map(fn
      %{"id" => id, "name" => name} ->
        case Repo.get(Flux.Chat.UploadedFile, id, skip_workspace_guard: true) do
          %{extracted_text: text} when is_binary(text) and text != "" ->
            ["[Attached file: #{name}]\n#{String.slice(text, 0, 8_000)}"]

          _no_text ->
            []
        end

      _malformed ->
        []
    end)
    |> Enum.join("\n\n")
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

  # The workspace-wide system prompt (compliance boilerplate, tone
  # rules) prefixes each app's own prompt on every model call.
  defp combined_system_prompt(app) do
    workspace_prompt = Flux.Accounts.system_prompt_for_workspace(app.workspace_id)
    app_prompt = app.system_prompt

    [workspace_prompt, app_prompt]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp atomize_params(params) do
    for {key, value} <- params,
        key in ~w(temperature max_tokens top_p stop frequency_penalty presence_penalty top_k seed),
        into: %{} do
      {String.to_existing_atom(key), value}
    end
  end

  defp format_error({:invalid_credentials, reason}), do: reason
  defp format_error({:http_error, status, _body}), do: "Provider returned HTTP #{status}."
  defp format_error(:timeout), do: "The model did not respond in time."
  defp format_error(other), do: "Generation failed: #{inspect(other)}"
end
