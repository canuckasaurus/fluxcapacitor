defmodule Flux.Chat.App do
  @moduledoc "A published chat application bound to a provider/model."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "apps" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :created_by, Flux.Accounts.Account

    field :name, :string
    field :description, :string
    # A short emoji avatar for console cards and the site header.
    field :icon, :string
    field :mode, Ecto.Enum, values: [:chat, :completion, :advanced_chat], default: :chat
    belongs_to :workflow, Flux.Workflows.Workflow
    field :provider_plugin_id, :string
    field :model, :string
    field :fallback_provider_plugin_id, :string
    field :fallback_model, :string
    # Further backups tried in order after the single fallback:
    # [%{"provider_plugin_id" => ..., "model" => ...}].
    field :fallbacks, {:array, :map}, default: []
    # Model A/B: ab_split% of conversations run the challenger model.
    field :ab_provider_plugin_id, :string
    field :ab_model, :string
    field :ab_split, :integer, default: 0
    field :system_prompt, :string
    # Prompt A/B: prompt_split% of conversations use prompt_b instead.
    field :prompt_b, :string
    field :prompt_split, :integer, default: 0
    field :prompt_template, :string
    field :input_form, {:array, :map}, default: []
    field :params, :map, default: %{}
    field :opening_statement, :string
    field :suggested_questions, {:array, :string}, default: []
    field :daily_token_limit, :integer
    field :rate_limit_per_minute, :integer
    field :annotation_threshold, :float
    field :suggest_followups, :boolean, default: false
    # Public sites show a pre-chat name/email form when set.
    field :collect_visitor_info, :boolean, default: false
    # Free-form labels for organizing the apps index.
    field :tags, {:array, :string}, default: []
    # Inbound-email webhook token (emch_…); nil = channel off.
    field :email_channel_token, :string
    # Slack channel: inbound events token (slch_…) + the bot token
    # replies post with (DEK-encrypted, set via enable_slack_channel).
    field :slack_channel_token, :string
    field :slack_bot_token, :string, redact: true
    # Monthly estimated-USD cap; past it the app answers like a spent
    # daily limit. nil = uncapped.
    field :monthly_cost_budget, :float
    # Highest budget threshold already notified, per month key
    # ("2026-08" => 80|100) — machine-managed, never cast.
    field :budget_alerts, :map, default: %{}
    # Origins allowed to iframe the published site (whitespace/newline
    # separated); blank keeps the embed-anywhere default.
    field :embed_origins, :string
    # Weekly site schedule (UTC): %{"days" => [...], "open" => h,
    # "close" => h, "note" => "..."}. Empty means always open.
    # Machine-shaped by the app page, never free-cast.
    field :business_hours, :map, default: %{}
    field :site_theme, :map, default: %{}
    field :site_token, :string
    field :site_enabled, :boolean, default: false
    # Optional gate on the public site: visitors enter the passcode once
    # per session. Set via Chat.set_site_passcode/3, never cast.
    field :site_passcode_hash, :string, redact: true
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [
      :name,
      :description,
      :icon,
      :mode,
      :workflow_id,
      :provider_plugin_id,
      :model,
      :fallback_provider_plugin_id,
      :fallback_model,
      :ab_provider_plugin_id,
      :ab_model,
      :ab_split,
      :system_prompt,
      :prompt_b,
      :prompt_split,
      :prompt_template,
      :fallbacks,
      :input_form,
      :params,
      :opening_statement,
      :suggested_questions,
      :daily_token_limit,
      :rate_limit_per_minute,
      :annotation_threshold,
      :suggest_followups,
      :collect_visitor_info,
      :tags,
      :monthly_cost_budget,
      :embed_origins,
      :business_hours,
      :site_theme
    ])
    |> validate_number(:monthly_cost_budget, greater_than: 0)
    |> validate_number(:daily_token_limit, greater_than: 0)
    |> validate_number(:rate_limit_per_minute, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:ab_split, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:prompt_split, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:annotation_threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:icon, max: 16)
    |> validate_mode_requirements()
  end

  # Chatflow apps are driven by a flux; the other modes call a model directly.
  defp validate_mode_requirements(changeset) do
    case get_field(changeset, :mode) do
      :advanced_chat -> validate_required(changeset, [:workflow_id])
      _direct_model -> validate_required(changeset, [:provider_plugin_id, :model])
    end
  end
end

defmodule Flux.Chat.Conversation do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :app, Flux.Chat.App
    field :title, :string
    field :end_user_ref, :string
    # Optional pre-chat identity (collect_visitor_info apps).
    field :visitor_name, :string
    field :visitor_email, :string
    # Handoff ownership: which member claimed this conversation.
    belongs_to :assigned_account, Flux.Accounts.Account
    field :labels, {:array, :string}, default: []
    # Resolve state: a human marked the thread done; a fresh visitor
    # message clears it.
    field :resolved_at, :utc_datetime
    # CSAT: the visitor's 1-5 rating and optional comment.
    field :csat_score, :integer
    field :csat_comment, :string
    # Read-only public transcript link; nil = not shared.
    field :share_token, :string
    # Set when a site visitor asks for a human; cleared on console reply.
    field :handoff_requested_at, :utc_datetime
    # Set once the overdue-handoff SLA warning fired for this request.
    field :handoff_alerted_at, :utc_datetime
    # Seconds from handoff request to the first human reply (set once).
    field :handoff_first_reply_seconds, :integer
    field :variables, :map, default: %{}
    # Rolling memory: older turns fold into `summary` once the history
    # outgrows the token window; `summarized_seq` is the last folded turn.
    field :summary, :string
    field :summarized_seq, :integer
    # Trash: soft-deleted, restorable for 30 days, then purged.
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Chat.Message do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :conversation, Flux.Chat.Conversation

    field :role, Ecto.Enum, values: [:user, :assistant]
    field :content, :string, default: ""
    # DB-assigned insertion order (UUIDv7 ids tie within a millisecond).
    field :seq, :integer, read_after_writes: true

    field :status, Ecto.Enum,
      values: [:completed, :streaming, :stopped, :error],
      default: :completed

    field :error, :string
    field :usage, :map, default: %{}
    field :citations, {:array, :map}, default: []
    field :files, {:array, :map}, default: []
    field :feedback, Ecto.Enum, values: [:like, :dislike]
    # Optional free-text alongside the rating — the "what was wrong".
    field :feedback_comment, :string
    # Read receipt: when the visitor's open tab saw this human reply.
    field :seen_at, :utc_datetime
    # Console-side bookmark: pinned messages surface in a strip above
    # the thread for quick reference.
    field :pinned, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Chat.Annotation do
  @moduledoc """
  A canonical answer for one question: matching queries (normalized
  exact match) answer instantly from the annotation instead of calling
  the model. Typically promoted from a liked reply in feedback review.
  """
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "annotations" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :app, Flux.Chat.App

    field :question, :string
    field :answer, :string
    field :enabled, :boolean, default: true
    field :hit_count, :integer, default: 0
    # Set when an embedding model was available at creation; powers the
    # app's optional similarity matching (annotation_threshold).
    field :embedding, {:array, :float}
    field :embedding_plugin_id, :string
    field :embedding_model, :string

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Chat.AppSnapshot do
  @moduledoc "A named copy of an app's settings — the undo apps never had."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "app_snapshots" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :app, Flux.Chat.App

    field :name, :string
    field :config, :map, default: %{}

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

defmodule Flux.Chat.ApiToken do
  @moduledoc """
  A hashed service-API token bound to one app (`app-…`) or one workflow
  (`flux-…`); the prefix names the binding.
  """
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_tokens" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :app, Flux.Chat.App
    belongs_to :workflow, Flux.Workflows.Workflow

    field :token_hash, :binary, redact: true
    field :prefix, :string
    # Set on ds- tokens: the key opens exactly one dataset's endpoints.
    # A plain id (the Dataset schema lives in flux_rag).
    field :dataset_id, :binary_id
    field :last_used_at, :utc_datetime
    # NULL = perpetual — both lifetimes are first-class choices.
    field :expires_at, :utc_datetime
    # NULL = the app/pipeline default; set, it caps THIS key's requests.
    field :rate_limit_per_minute, :integer
    # Set when the expiring-key warning fired, so it fires exactly once.
    field :expiry_warned_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Chat.UploadedFile do
  @moduledoc "A file stored via Flux.Storage, uploaded through /v1/files/upload."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "uploaded_files" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :app, Flux.Chat.App

    field :name, :string
    field :key, :string
    field :size, :integer
    field :content_type, :string
    field :end_user_ref, :string
    field :download_token, :string
    # Text pulled out of document uploads at store time (Tika / native),
    # so chat turns can carry the file's content without re-extracting.
    field :extracted_text, :string

    timestamps(type: :utc_datetime)
  end
end

defmodule Flux.Chat.ConversationNote do
  @moduledoc "An agent-only comment on a conversation, never shown to the visitor."
  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_notes" do
    belongs_to :workspace, Flux.Accounts.Workspace
    belongs_to :conversation, Flux.Chat.Conversation

    field :author_email, :string
    field :body, :string

    timestamps(type: :utc_datetime)
  end
end
