defmodule Flux.Repo.Migrations.Batch34 do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :expiry_warned_at, :utc_datetime
    end

    alter table(:messages) do
      add :feedback_comment, :text
    end

    alter table(:workflows) do
      add :site_passcode_hash, :string
    end
  end
end
