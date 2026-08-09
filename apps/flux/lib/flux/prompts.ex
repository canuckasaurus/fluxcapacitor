defmodule Flux.Prompts do
  @moduledoc """
  The workspace prompt library: named, reusable prompt snippets. The
  editor's LLM/agent panels insert them by picker — a copy at insert
  time, so published graphs never dangle on a deleted snippet.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.RBAC
  alias Flux.Repo

  defmodule Snippet do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "prompt_snippets" do
      belongs_to :workspace, Flux.Accounts.Workspace

      field :name, :string
      field :content, :string

      timestamps(type: :utc_datetime)
    end

    def changeset(snippet, attrs) do
      snippet
      |> cast(attrs, [:name, :content])
      |> validate_required([:name, :content])
      |> validate_length(:name, min: 1, max: 120)
      |> unique_constraint([:workspace_id, :name])
    end
  end

  defmodule SnippetVersion do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "prompt_snippet_versions" do
      belongs_to :workspace, Flux.Accounts.Workspace
      belongs_to :snippet, Flux.Prompts.Snippet

      field :version, :integer
      field :content, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end

  def list(%Scope{} = scope) do
    Snippet |> Repo.scoped(scope) |> order_by([s], asc: s.name) |> Repo.all()
  end

  @doc """
  Creates or replaces a snippet. Overwrites archive the previous content
  as a numbered version first, so edits never lose history.
  """
  def upsert(%Scope{} = scope, name, content) do
    workspace_id = Scope.workspace_id(scope)

    with :ok <- RBAC.authorize(scope, :app_edit) do
      existing = Repo.one(Repo.scoped(where(Snippet, name: ^to_string(name)), scope))

      if existing && existing.content != content do
        archive_version(existing)
      end

      %Snippet{workspace_id: workspace_id}
      |> Snippet.changeset(%{"name" => name, "content" => content})
      |> Repo.insert(
        on_conflict: {:replace, [:content, :updated_at]},
        conflict_target: [:workspace_id, :name],
        # Upserts must hand back the persisted row's id, not a phantom.
        returning: true
      )
    end
  end

  @doc "A snippet's archived versions, newest first."
  def versions(%Scope{} = scope, snippet_id) do
    SnippetVersion
    |> Repo.scoped(scope)
    |> where([v], v.snippet_id == ^snippet_id)
    |> order_by([v], desc: v.version)
    |> Repo.all()
  end

  @doc "Restores an archived version (the current content archives first)."
  def restore_version(%Scope{} = scope, snippet_id, version) when is_integer(version) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Snippet{} = snippet <-
           Repo.one(Repo.scoped(where(Snippet, id: ^snippet_id), scope)) ||
             {:error, :not_found},
         %SnippetVersion{} = archived <-
           Repo.one(
             Repo.scoped(
               where(SnippetVersion, snippet_id: ^snippet_id, version: ^version),
               scope
             )
           ) || {:error, :not_found} do
      upsert(scope, snippet.name, archived.content)
    end
  end

  defp archive_version(%Snippet{} = snippet) do
    next =
      (SnippetVersion
       |> where([v], v.snippet_id == ^snippet.id)
       |> select([v], max(v.version))
       |> Repo.one(skip_workspace_guard: true) || 0) + 1

    Repo.insert!(%SnippetVersion{
      workspace_id: snippet.workspace_id,
      snippet_id: snippet.id,
      version: next,
      content: snippet.content
    })
  end

  def delete(%Scope{} = scope, snippet_id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %Snippet{} = snippet <-
           Repo.one(Repo.scoped(where(Snippet, id: ^snippet_id), scope)) ||
             {:error, :not_found} do
      Repo.delete(snippet)
    end
  end
end
