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
    field :mode, Ecto.Enum, values: [:chat, :completion, :advanced_chat], default: :chat
    belongs_to :workflow, Flux.Workflows.Workflow
    field :provider_plugin_id, :string
    field :model, :string
    field :fallback_provider_plugin_id, :string
    field :fallback_model, :string
    field :system_prompt, :string
    field :prompt_template, :string
    field :input_form, {:array, :map}, default: []
    field :params, :map, default: %{}
    field :opening_statement, :string
    field :suggested_questions, {:array, :string}, default: []
    field :daily_token_limit, :integer
    field :rate_limit_per_minute, :integer
    field :annotation_threshold, :float
    field :suggest_followups, :boolean, default: false
    field :site_theme, :map, default: %{}
    field :site_token, :string
    field :site_enabled, :boolean, default: false
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [
      :name,
      :description,
      :mode,
      :workflow_id,
      :provider_plugin_id,
      :model,
      :fallback_provider_plugin_id,
      :fallback_model,
      :system_prompt,
      :prompt_template,
      :input_form,
      :params,
      :opening_statement,
      :suggested_questions,
      :daily_token_limit,
      :rate_limit_per_minute,
      :annotation_threshold,
      :suggest_followups,
      :site_theme
    ])
    |> validate_number(:daily_token_limit, greater_than: 0)
    |> validate_number(:rate_limit_per_minute, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:annotation_threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
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
    field :labels, {:array, :string}, default: []
    # Set when a site visitor asks for a human; cleared on console reply.
    field :handoff_requested_at, :utc_datetime
    field :variables, :map, default: %{}
    # Rolling memory: older turns fold into `summary` once the history
    # outgrows the token window; `summarized_seq` is the last folded turn.
    field :summary, :string
    field :summarized_seq, :integer

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
    field :last_used_at, :utc_datetime
    # NULL = perpetual — both lifetimes are first-class choices.
    field :expires_at, :utc_datetime

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

    timestamps(type: :utc_datetime)
  end
end
