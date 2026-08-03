defmodule Flux.Registry do
  @moduledoc """
  The model registry: run artifacts (trained models, encoders, indexes)
  promoted to named, versioned entries — "ticket-intent v3" instead of a
  raw file id. Registering the same name again auto-increments the
  version; the code-node attachment picker lists the latest version of
  every name, which closes the train → serve loop with something a team
  can actually operate.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.RBAC
  alias Flux.Repo

  defmodule ModelArtifact do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "model_artifacts" do
      belongs_to :workspace, Flux.Accounts.Workspace
      belongs_to :file, Flux.Chat.UploadedFile
      belongs_to :source_run, Flux.Workflows.WorkflowRun

      field :name, :string
      field :version, :integer
      field :metrics, :map, default: %{}

      timestamps(type: :utc_datetime)
    end
  end

  @doc """
  Registers a stored file under a model name — version auto-increments
  per name. `metrics` is free-form (accuracy, size, notes).
  """
  def register(%Scope{} = scope, name, file_id, opts \\ []) do
    name = name |> to_string() |> String.trim()

    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- name != "" || {:error, :blank_name},
         %Flux.Chat.UploadedFile{} = file <- fetch_file(scope, file_id) do
      version = next_version(scope, name)

      {:ok,
       Repo.insert!(%ModelArtifact{
         workspace_id: file.workspace_id,
         file_id: file.id,
         source_run_id: Keyword.get(opts, :source_run_id),
         name: name,
         version: version,
         metrics: Keyword.get(opts, :metrics, %{})
       })}
    else
      nil -> {:error, :file_not_found}
      other -> other
    end
  end

  @doc "Every registered model, newest version of each name first."
  def list(%Scope{} = scope) do
    ModelArtifact
    |> Repo.scoped(scope)
    |> order_by([m], asc: m.name, desc: m.version)
    |> preload(file: ^scoped_files(scope))
    |> Repo.all()
  end

  @doc "The latest version per name — what the attachment picker offers."
  def latest(%Scope{} = scope) do
    ModelArtifact
    |> Repo.scoped(scope)
    |> distinct([m], m.name)
    |> order_by([m], asc: m.name, desc: m.version)
    |> preload(file: ^scoped_files(scope))
    |> Repo.all()
  end

  # Preload queries pass the tenancy guard by carrying the workspace
  # filter themselves.
  defp scoped_files(scope), do: Repo.scoped(Flux.Chat.UploadedFile, scope)

  def delete(%Scope{} = scope, artifact_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %ModelArtifact{} = artifact <-
           Repo.one(Repo.scoped(where(ModelArtifact, id: ^artifact_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(artifact)
    end
  end

  defp next_version(scope, name) do
    (ModelArtifact
     |> Repo.scoped(scope)
     |> where([m], m.name == ^name)
     |> select([m], max(m.version))
     |> Repo.one() || 0) + 1
  end

  defp fetch_file(scope, file_id) do
    case Ecto.UUID.cast(to_string(file_id)) do
      {:ok, _uuid} ->
        Repo.one(Repo.scoped(where(Flux.Chat.UploadedFile, id: ^file_id), scope))

      :error ->
        nil
    end
  end
end
