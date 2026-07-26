defmodule Flux.Repo.Migrations.CreateProvidersAppsChat do
  use Ecto.Migration

  def change do
    create table(:provider_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :plugin_id, :string, null: false
      add :name, :string, null: false, default: "default"
      add :encrypted_config, :text, null: false
      add :validated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_credentials, [:workspace_id, :plugin_id, :name])

    create table(:apps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :mode, :string, null: false, default: "chat"
      add :provider_plugin_id, :string, null: false
      add :model, :string, null: false
      add :system_prompt, :text
      add :params, :map, null: false, default: %{}
      add :created_by_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:apps, [:workspace_id])

    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string
      add :end_user_ref, :string

      timestamps(type: :utc_datetime)
    end

    create index(:conversations, [:workspace_id])
    create index(:conversations, [:app_id, :inserted_at])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false
      add :content, :text, null: false, default: ""
      add :status, :string, null: false, default: "completed"
      add :error, :text
      add :usage, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:workspace_id])
    create index(:messages, [:conversation_id, :inserted_at])

    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :prefix, :string, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:app_id])
  end
end
