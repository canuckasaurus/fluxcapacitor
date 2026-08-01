defmodule Flux.Repo.Migrations.MessageSeq do
  use Ecto.Migration

  # UUIDv7 ids are time-ordered only to the millisecond — a user message
  # and its assistant reply inserted in the same millisecond can sort
  # either way. A DB-assigned sequence makes insertion order the truth.
  def change do
    alter table(:messages) do
      add :seq, :bigserial
    end

    create index(:messages, [:conversation_id, :seq])
  end
end
