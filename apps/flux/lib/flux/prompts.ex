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

  def list(%Scope{} = scope) do
    Snippet |> Repo.scoped(scope) |> order_by([s], asc: s.name) |> Repo.all()
  end

  def upsert(%Scope{} = scope, name, content) do
    with :ok <- RBAC.authorize(scope, :app_edit) do
      %Snippet{workspace_id: Scope.workspace_id(scope)}
      |> Snippet.changeset(%{"name" => name, "content" => content})
      |> Repo.insert(
        on_conflict: {:replace, [:content, :updated_at]},
        conflict_target: [:workspace_id, :name]
      )
    end
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
