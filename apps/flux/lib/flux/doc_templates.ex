defmodule Flux.DocTemplates do
  @moduledoc """
  User-provided document templates: reusable Jinja documents (offer
  letters, reports, emails, invoices) that template nodes plug into via
  `template_id`. The library lives per workspace; content is rendered by
  `Flux.Engine.Jinja` at run time with the run's variable pool.
  """

  import Ecto.Query

  alias Flux.Accounts.Scope
  alias Flux.RBAC
  alias Flux.Repo

  defmodule DocTemplate do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, UUIDv7, autogenerate: true}
    @foreign_key_type :binary_id

    schema "doc_templates" do
      belongs_to :workspace, Flux.Accounts.Workspace
      field :name, :string
      field :description, :string
      field :content, :string

      timestamps(type: :utc_datetime)
    end

    def changeset(template, attrs) do
      template
      |> cast(attrs, [:name, :description, :content])
      |> validate_required([:name, :content])
      |> validate_length(:name, min: 1, max: 120)
      |> validate_length(:content, max: 100_000)
      |> validate_jinja()
      |> unique_constraint([:workspace_id, :name])
    end

    # Saving a template that cannot parse would only fail later at run
    # time — reject it here with the renderer's own message.
    defp validate_jinja(changeset) do
      validate_change(changeset, :content, fn :content, content ->
        case Flux.Engine.Jinja.render(content, %{}) do
          {:ok, _output} -> []
          {:error, message} -> [content: "invalid template: #{message}"]
        end
      end)
    end
  end

  def list(%Scope{} = scope) do
    DocTemplate |> Repo.scoped(scope) |> order_by([t], asc: t.name) |> Repo.all()
  end

  def get(%Scope{} = scope, id) do
    Repo.one(Repo.scoped(where(DocTemplate, id: ^id), scope)) || {:error, :not_found}
  end

  def create(%Scope{} = scope, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         {:ok, template} <-
           %DocTemplate{workspace_id: Scope.workspace_id(scope)}
           |> DocTemplate.changeset(attrs)
           |> Repo.insert() do
      Flux.Audit.record(scope, "doc_template.create",
        resource_type: "doc_template",
        resource_id: template.id,
        metadata: %{"name" => template.name}
      )

      {:ok, template}
    end
  end

  def update(%Scope{} = scope, %DocTemplate{} = template, attrs) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         true <- template.workspace_id == Scope.workspace_id(scope) || {:error, :not_found},
         {:ok, updated} <- template |> DocTemplate.changeset(attrs) |> Repo.update() do
      Flux.Audit.record(scope, "doc_template.update",
        resource_type: "doc_template",
        resource_id: template.id,
        metadata: %{"name" => updated.name}
      )

      {:ok, updated}
    end
  end

  def delete(%Scope{} = scope, id) do
    with :ok <- RBAC.authorize(scope, :app_edit),
         %DocTemplate{} = template <-
           Repo.one(Repo.scoped(where(DocTemplate, id: ^id), scope)) || {:error, :not_found},
         {:ok, deleted} <- Repo.delete(template) do
      Flux.Audit.record(scope, "doc_template.delete",
        resource_type: "doc_template",
        resource_id: template.id,
        metadata: %{"name" => template.name}
      )

      {:ok, deleted}
    end
  end

  @doc "Content lookup for the engine's fetch_doc_template capability."
  def fetch_content(workspace_id, template_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(template_id),
         %DocTemplate{content: content} <-
           Repo.one(
             from(t in DocTemplate,
               where: t.workspace_id == ^workspace_id and t.id == ^template_id
             )
           ) do
      {:ok, content}
    else
      _missing -> {:error, "doc template not found"}
    end
  end
end
