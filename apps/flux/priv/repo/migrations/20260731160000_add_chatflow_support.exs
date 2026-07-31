defmodule Flux.Repo.Migrations.AddChatflowSupport do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :workflow_id, references(:workflows, type: :uuid, on_delete: :nilify_all)

      # Chatflow apps are flux-driven; the model pair is only required for
      # chat/completion modes (enforced in the changeset).
      modify :provider_plugin_id, :string, null: true, from: {:string, null: false}
      modify :model, :string, null: true, from: {:string, null: false}
    end

    alter table(:conversations) do
      add :variables, :map, default: %{}, null: false
    end
  end
end
