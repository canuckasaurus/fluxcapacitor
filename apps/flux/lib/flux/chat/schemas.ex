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
    field :mode, Ecto.Enum, values: [:chat], default: :chat
    field :provider_plugin_id, :string
    field :model, :string
    field :system_prompt, :string
    field :params, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [:name, :description, :provider_plugin_id, :model, :system_prompt, :params])
    |> validate_required([:name, :provider_plugin_id, :model])
    |> validate_length(:name, min: 1, max: 255)
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

    field :status, Ecto.Enum,
      values: [:completed, :streaming, :stopped, :error],
      default: :completed

    field :error, :string
    field :usage, :map, default: %{}

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

    timestamps(type: :utc_datetime)
  end
end
