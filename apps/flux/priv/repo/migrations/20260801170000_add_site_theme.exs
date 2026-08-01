defmodule Flux.Repo.Migrations.AddSiteTheme do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      # %{"accent" => "#hex", "title" => override, "logo_url" => optional}
      add :site_theme, :map, default: %{}, null: false
    end
  end
end
