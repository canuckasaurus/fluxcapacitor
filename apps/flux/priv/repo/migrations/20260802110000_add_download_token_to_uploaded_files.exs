defmodule Flux.Repo.Migrations.AddDownloadTokenToUploadedFiles do
  use Ecto.Migration

  def change do
    alter table(:uploaded_files) do
      add :download_token, :string
    end

    create unique_index(:uploaded_files, [:download_token])
  end
end
