defmodule Flux.Repo.Migrations.WorkflowSiteTheme do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :site_theme, :map, default: %{}, null: false
    end
  end
end
