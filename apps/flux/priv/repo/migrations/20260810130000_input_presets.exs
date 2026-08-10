defmodule Flux.Repo.Migrations.InputPresets do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :input_presets, :map, null: false, default: %{}
    end
  end
end
